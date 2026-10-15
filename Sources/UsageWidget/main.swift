import AppKit
import UserNotifications
import UsageCore
import UsageTransport

let appID = "io.github.dwagwd.quotapilot"
if CommandLine.arguments.contains("--quit") {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(appID+".quit"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaPilot", isDirectory: true)
migrateFromCodexUsageWidget()
try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let lockFD = open(support.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(appID+".show"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

/// One-time move from the pre-rename "Codex Usage Widget": data folder (the old path stays as a symlink so
/// installed status-line bridges keep working) and preferences.
func migrateFromCodexUsageWidget() {
    let fm = FileManager.default
    let legacy = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexUsageWidget", isDirectory: true)
    var isLink = false
    if let type = try? fm.attributesOfItem(atPath: legacy.path)[.type] as? FileAttributeType { isLink = type == .typeSymbolicLink }
    if !isLink, fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: support.path) {
        if (try? fm.moveItem(at: legacy, to: support)) != nil {
            try? fm.createSymbolicLink(at: legacy, withDestinationURL: support)
        }
    }
    let defaults = UserDefaults.standard
    if defaults.object(forKey: "settings") == nil, let old = UserDefaults(suiteName: "local.codex.usage-widget") {
        for (key, value) in old.dictionaryRepresentation() where old.object(forKey: key) != nil && !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
            defaults.set(value, forKey: key)
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class ColorOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class CardBackground: NSVisualEffectView {
    private var dragStart: NSPoint?
    private var originalOrigin: NSPoint?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        dragStart = window?.convertPoint(toScreen: event.locationInWindow)
        originalOrigin = window?.frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart, let originalOrigin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: originalOrigin.x+point.x-dragStart.x,
                                      y: originalOrigin.y+point.y-dragStart.y))
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil; originalOrigin = nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let client = UsageClient()
    private var panel: FloatingPanel!
    private var status: NSStatusItem!
    private let defaults = UserDefaults.standard
    private var history = History()
    private var tokenHistory = TokenHistory()
    private var taskLedger = TaskLedger()
    private var accountObservations = AccountObservationLedger()
    private var usageEventLedger = UsageEventLedger()
    private var pendingUsageEventWrites: [UsageLedgerEvent] = []
    private let maxPendingUsageEventWrites = 1_000
    private var quotaAlertTracker = QuotaAlertTracker()
    private var autoContinuePlanner = AutoContinuePlanner()
    private var autoContinueRunning = false
    private var lastAutoContinue: (at: Double, session: String?, result: String)?
    private let agentScanQueue = DispatchQueue(label: "io.github.dwagwd.quotapilot.agent-logs", qos: .utility)
    private var agentScanner = AgentLogScanner(sources: AgentLogScanner.defaultSources(home: FileManager.default.homeDirectoryForCurrentUser))
    private var agentLedger = AgentTokenLedger()
    private var agentScanning = false
    private var agentLastScanAt: Double?
    private var agentTick: Timer?
    private let agentsLabel = NSTextField(labelWithString: "")
    private var deepSeekBalances: [DeepSeekBalance] = []
    private var deepSeekError = false
    private var deepSeekTick: Timer?
    private var autoConnectTick: Timer?
    private var autoConnectResults: [String: String] = [:]
    private var claudePlanTick: Timer?
    private var statsStore = UsageStatsStore()
    private let statsModel = StatsModel()
    private var statsWindow: StatsWindowController?
    private var claudePlanError: String?
    private var claudePlanFetching = false
    private let usageEventFileRotationBytes: UInt64 = 20 * 1_048_576
    private var usageEventLastAttemptAt: Double?
    private var usageEventLastSuccessAt: Double?
    private var usageEventLastErrorCode: String?
    private var usageEventIntegrityErrorCode: String?
    private var usageEventConsecutiveFailures = 0
    private var tokenAvailable = false
    private var settings = WidgetSettings()
    private var settingsWindow: SettingsWindowController?
    private var l: L10n { L10n(settings.language) }
    private var items: [WindowItem] = []
    private var codexItems: [WindowItem] = []
    private var bridgeSnapshots: [String: ProviderSnapshot] = [:]
    private var bridgeHistories: [String: History] = [:]
    private var bridgeDates: [String: Date] = [:]
    private var bridgeLastAttempt: [String: Double] = [:]
    private var bridgeLastError: [String: String] = [:]
    private var bridgeFailureCounts: [String: Int] = [:]
    private var bridgeTick: Timer?
    private var extraLabels: [NSTextField] = []
    private var cachedRates: [String: Rate] = [:]
    private var cachedTokenRate: Rate?
    private var ratesDirty = true
    private var lastFreshness: [Bool] = []
    private let dateFormatter = DateFormatter()
    private static let extraRowHeight: CGFloat = 16
    /// Extra windows grouped by provider, so a 5-hour and a weekly limit share one compact line.
    private var extraGroups: [[WindowItem]] {
        var order: [String] = [], groups: [String: [WindowItem]] = [:]
        let extras = extraItems
        let currentProvider = current.map { String($0.id.split(separator: ":").first ?? "") }
        // The selected window's siblings stay on one line with it, e.g. 5h next to the weekly limit.
        let siblings = extras.contains { String($0.id.split(separator: ":").first ?? "") == currentProvider } ? [current].compactMap { $0 } : []
        for item in siblings + extras {
            let key = String(item.id.split(separator: ":").first ?? "")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return sortQuotaGroups(order.compactMap { groups[$0]?.sorted { ($0.window.windowDurationMins ?? .max) < ($1.window.windowDurationMins ?? .max) } },
                               sort: settings.quotaSort ?? .detected, pinned: settings.pinnedProviders ?? [], now: Date().timeIntervalSince1970)
    }
    private func shortWindow(_ minutes: Int?) -> String {
        guard let m = minutes, m > 0 else { return "?" }
        if m == 10080 { return l.text("weekTag") }
        if m % 1440 == 0 { return "\(m / 1440)d" }
        if m % 60 == 0 { return "\(m / 60)h" }
        return "\(m)m"
    }
    private func shortCountdown(_ reset: Double?, now: Double) -> String {
        guard let reset, reset > now else { return "" }
        let s = Int(reset - now)
        if s >= 86400 { return "↻\(s / 86400)d\(s % 86400 / 3600)h" }
        if s >= 3600 { return "↻\(s / 3600)h\(s % 3600 / 60)m" }
        return "↻\(max(1, s / 60))m"
    }
    /// e.g. `Claude  5h 24% ↻2h10m  週 95% ↻4h5m`
    private func compactLine(_ group: [WindowItem], now: Double) -> String {
        let name = group.first?.name ?? ""
        return name + "  " + group.map { item in
            let stale = isStale(item, now: now)
            let pct = item.window.validUsedPercent.map { l.number($0, decimals: 0) + "%" } ?? "—"
            return shortWindow(item.window.windowDurationMins) + " " + pct + (stale ? " ⚠︎" : " " + shortCountdown(item.window.resetsAt, now: now))
        }.joined(separator: "  ")
    }
    private var cardStyle: CardStyle { settings.cardStyle ?? .detailed }
    private var styledViews: [NSView] = []
    private var styledLines: [(label: NSTextField, group: Int)] = []
    private var styledBars: [(bar: NSProgressIndicator, text: NSTextField, group: Int, window: Int)] = []
    /// Every quota window grouped by provider, for the compact and bar styles.
    private var providerGroups: [[WindowItem]] {
        var order: [String] = [], groups: [String: [WindowItem]] = [:]
        for item in items {
            let key = String(item.id.split(separator: ":").first ?? "")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return sortQuotaGroups(order.compactMap { groups[$0]?.sorted { ($0.window.windowDurationMins ?? .max) < ($1.window.windowDurationMins ?? .max) } },
                               sort: settings.quotaSort ?? .detected, pinned: settings.pinnedProviders ?? [], now: Date().timeIntervalSince1970)
    }
    private func providerKey(_ group: [WindowItem]) -> String { String(group.first?.id.split(separator: ":").first ?? "") }
    /// Quota rate of the shortest window plus the provider's tokens in the observation window.
    private func providerExtras(_ group: [WindowItem], now: Double) -> String {
        var parts: [String] = []
        if let first = group.first, !isStale(first, now: now), let rate = cachedRates[first.id] {
            parts.append("≈" + l.rateNumber(rate.value(per: settings.rateUnit)) + "%/" + l.unit(settings.rateUnit, short: true))
        }
        let tokens = agentLedger.summary(since: now - settings.lookback, now: now)[providerKey(group)]?.total ?? 0
        if tokens > 0 { parts.append(l.compact(tokens)) }
        return parts.joined(separator: " ")
    }
    private func styledTitle(now: Double) -> String {
        let total = agentLedger.total(since: now - settings.lookback, now: now).total
        guard settings.agentLogsEnabled, agentLastScanAt != nil else { return l.text("allAgents") + " · " + l.text("collecting") + " ▾" }
        let perUnit = total / max(settings.lookback, 60) * settings.rateUnit.seconds
        return l.text("allAgents") + " " + l.compact(total) + " · ≈" + l.compact(perUnit) + "/" + l.unit(settings.rateUnit, short: true) + " ▾"
    }
    private func layoutStyled() {
        styledViews.forEach { $0.removeFromSuperview() }; styledViews = []; styledLines = []; styledBars = []
        guard !collapsed, cardStyle != .detailed, let content = panel.contentView else { return }
        let groups = providerGroups
        let width: CGFloat = cardStyle == .compact ? 300 : 260
        let rows = groups.map { cardStyle == .compact ? CGFloat(16) : 15 + CGFloat($0.count) * 13 }
        let height = 30 + rows.reduce(0, +) + 6
        let old = panel.frame
        // Keep the right edge in place: the card usually sits in the top-right corner.
        panel.setFrame(NSRect(x: old.maxX - width, y: old.maxY - height, width: width, height: height), display: true)
        if !NSScreen.screens.isEmpty { panel.setFrameOrigin(visibleOrigin(for: panel.frame, screens: NSScreen.screens.map(\.visibleFrame))) }
        titleButton.frame = NSRect(x: 10, y: height - 27, width: width - 58, height: 20)
        settingsButton.frame = NSRect(x: width - 44, y: height - 27, width: 20, height: 20)
        foldButton.frame = NSRect(x: width - 22, y: height - 27, width: 18, height: 20)
        func label(_ font: NSFont, _ frame: NSRect) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.font = font; field.lineBreakMode = .byTruncatingTail; field.frame = frame
            content.addSubview(field); styledViews.append(field); return field
        }
        var y = height - 30
        for (index, group) in groups.enumerated() {
            if cardStyle == .compact {
                y -= 16
                styledLines.append((label(.monospacedDigitSystemFont(ofSize: 10, weight: .regular), NSRect(x: 12, y: y, width: width - 24, height: 14)), index))
            } else {
                y -= 15
                styledLines.append((label(.systemFont(ofSize: 10, weight: .semibold), NSRect(x: 12, y: y, width: width - 24, height: 14)), index))
                for windowIndex in group.indices {
                    y -= 13
                    let tag = label(.monospacedDigitSystemFont(ofSize: 9, weight: .regular), NSRect(x: 12, y: y, width: 26, height: 12))
                    tag.stringValue = shortWindow(group[windowIndex].window.windowDurationMins)
                    let bar = NSProgressIndicator(frame: NSRect(x: 40, y: y + 3, width: 112, height: 6))
                    bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 100; bar.controlSize = .mini
                    content.addSubview(bar); styledViews.append(bar)
                    let text = label(.monospacedDigitSystemFont(ofSize: 9, weight: .regular), NSRect(x: 158, y: y, width: width - 170, height: 12))
                    styledBars.append((bar, text, index, windowIndex))
                }
            }
        }
    }
    private func renderStyled(now: Double) {
        guard !collapsed, cardStyle != .detailed else { return }
        let groups = providerGroups
        titleButton.title = styledTitle(now: now)
        for (field, index) in styledLines where index < groups.count {
            let group = groups[index]
            let extras = providerExtras(group, now: now)
            let text = cardStyle == .compact ? compactLine(group, now: now) + (extras.isEmpty ? "" : "  " + extras)
                                             : (group.first?.name ?? "") + (extras.isEmpty ? "" : "  " + extras)
            if field.stringValue != text { field.stringValue = text }
            field.textColor = group.contains { ($0.window.validUsedPercent ?? 0) >= 90 } ? .systemOrange : .labelColor
            field.toolTip = group.map { title(for: $0) + " · " + resetText($0, now: now) }.joined(separator: "\n")
        }
        for row in styledBars where row.group < groups.count && row.window < groups[row.group].count {
            let item = groups[row.group][row.window]
            let used = item.window.validUsedPercent
            row.bar.doubleValue = used ?? 0
            let text = (used.map { l.number($0, decimals: 0) + "%" } ?? "—") + " " + (isStale(item, now: now) ? "⚠︎" : shortCountdown(item.window.resetsAt, now: now))
            if row.text.stringValue != text { row.text.stringValue = text }
            row.text.textColor = (used ?? 0) >= 90 ? .systemOrange : .labelColor
            row.text.toolTip = title(for: item) + " · " + resetText(item, now: now)
        }
    }
    private var extraItems: [WindowItem] {
        guard settings.options.multiple else { return [] }
        return Array(items.filter { $0.id != current?.id && settings.options.windowIDs.contains($0.id) }.prefix(4))
    }
    private var selectedID: String?
    private var lastUpdate: Date?
    private var errorMessage: String? = "connecting"
    private var sleeping = false
    private var tick: Timer?
    private var collapsed = false
    private var pinned = true
    private var adjustingFrame = false
    private let titleButton = NSButton()
    private let foldButton = NSButton()
    private let settingsButton = NSButton()
    private let valueLabel = NSTextField(labelWithString: "—")
    private let resetLabel = NSTextField(labelWithString: "正在取得用量…")
    private let rateLabel = NSTextField(labelWithString: "近1小時 · 累積資料中")
    private let tokenLabel = NSTextField(labelWithString: "—")
    private let observationLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let colorOverlay = ColorOverlay()
    private var current: WindowItem? { items.first { $0.id == selectedID } ?? items.first }
    private var stale: Bool { lastUpdate.map { Date().timeIntervalSince($0) > self.client.pollInterval + 30 } ?? true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        collapsed = defaults.bool(forKey: "collapsed")
        pinned = defaults.object(forKey: "pinned") as? Bool ?? true
        selectedID = defaults.string(forKey: "selectedWindow")
        if let data = try? Data(contentsOf: support.appendingPathComponent("history.json")),
           let saved = try? JSONDecoder().decode(History.self, from: data) { history = saved }
        if let data = defaults.data(forKey: "settings"), let decoded = try? JSONDecoder().decode(WidgetSettings.self, from: data), decoded.isValid { settings = decoded }
        if let data = try? Data(contentsOf: support.appendingPathComponent("tokens.json")), let saved = try? JSONDecoder().decode(TokenHistory.self, from: data) { tokenHistory = saved }
        if let saved = loadPrivateLedger(TaskLedger.self, named: "task-ledger.json") { taskLedger = saved }
        if let saved = loadPrivateLedger(AccountObservationLedger.self, named: "account-observations.json") { accountObservations = saved }
        loadUsageEventLedger()
        if let saved = loadPrivateLedger(UsageStatsStore.self, named: "usage-stats.json") { statsStore = saved }
        client.pollInterval = settings.options.energySaver ? 120 : 60
        setupPanel(); setupStatus()
        requestAlertAuthorizationIfNeeded()
        client.onResult = { [weak self] response, account in self?.received(response, account: account) }
        client.onTokens = { [weak self] total, account in
            guard let self else { return }
            self.tokenAvailable = total.map { $0.isFinite && $0 >= 0 } ?? false
            let now = Date().timeIntervalSince1970
            self.tokenHistory.record(account: account, total: total, now: now)
            if let data = try? JSONEncoder().encode(self.tokenHistory) { try? data.write(to: support.appendingPathComponent("tokens.json"), options: .atomic) }
            self.recordUsageObservation(account: account, tokenTotal: total, now: now)
            self.ratesDirty = true; self.render(); self.writeStatus()
        }
        client.onFailure = { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            self.recordUsageFailure(sourceID: "codex.quota", errorCode: message,
                                    accountKey: self.history.account, now: Date().timeIntervalSince1970)
            self.render(); self.writeStatus()
        }
        client.onDiagnostics = { [weak self] _ in
            self?.render(); self?.writeStatus()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showPanel), name: Notification.Name(appID+".show"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(quit), name: Notification.Name(appID+".quit"), object: nil)
        startUITimer()
        bridgeTick = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, !self.sleeping else { return }; self.reloadBridges()
        }
        bridgeTick?.tolerance = 3
        RunLoop.main.add(bridgeTick!, forMode: .common)
        reloadBridges()
        agentTick = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, !self.sleeping else { return }; self.scanAgentLogs()
        }
        agentTick?.tolerance = 10
        RunLoop.main.add(agentTick!, forMode: .common)
        backfillStats()
        scanAgentLogs()
        deepSeekTick = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            guard let self, !self.sleeping else { return }; self.refreshDeepSeek()
        }
        deepSeekTick?.tolerance = 60
        RunLoop.main.add(deepSeekTick!, forMode: .common)
        refreshDeepSeek()
        autoConnectTick = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in self?.autoConnectAgents() }
        autoConnectTick?.tolerance = 120
        RunLoop.main.add(autoConnectTick!, forMode: .common)
        autoConnectAgents()
        claudePlanTick = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            guard let self, !self.sleeping else { return }; self.refreshClaudePlan()
        }
        claudePlanTick?.tolerance = 15
        RunLoop.main.add(claudePlanTick!, forMode: .common)
        refreshClaudePlan()
        showPanel(); client.refresh()
    }
    private func startUITimer() {
        tick?.invalidate()
        guard !sleeping else { return }
        tick = Timer(timeInterval: settings.options.energySaver ? 15 : 1, repeats: true) { [weak self] _ in
            guard let self, !self.sleeping, self.panel.isVisible else { return }
            self.renderCountdown()
        }
        tick?.tolerance = settings.options.energySaver ? 3 : 0.2
        RunLoop.main.add(tick!, forMode: .common)
    }
    private func renderCountdown() {
        let now = Date().timeIntervalSince1970
        let tokenStale = !tokenAvailable || client.diagnostics.lastTokenSuccessAt.map { now - $0 > client.pollInterval + 30 } ?? true
        let freshness = items.map { isStale($0, now: now) || ($0.window.resetsAt.map { $0 <= now } ?? false) } + [stale, tokenStale]
        if freshness != lastFreshness { render(); writeStatus(); return }
        guard !collapsed else { return }
        if cardStyle != .detailed { renderStyled(now: now); return }
        if let item = current {
            let value = isStale(item, now: now) ? l.text("stale") + " · " + l.countdown(item.window.resetsAt, now: now) : resetText(item, now: now)
            if resetLabel.stringValue != value { resetLabel.stringValue = value }
        }
        for (index, group) in extraGroups.enumerated() where index < extraLabels.count {
            let value = compactLine(group, now: now)
            if extraLabels[index].stringValue != value { extraLabels[index].stringValue = value }
        }
    }
    private func applyColors() {
        func color(_ rgb: UsageCore.RGBColor) -> NSColor { NSColor(srgbRed: Double(rgb.red)/255, green: Double(rgb.green)/255, blue: Double(rgb.blue)/255, alpha: 1) }
        let custom = settings.options.customColors
        let foreground = custom ? color(settings.options.foreground) : NSColor.labelColor
        if let bg = panel.contentView as? CardBackground {
            bg.state = custom ? .inactive : .active
            colorOverlay.isHidden = !custom
            colorOverlay.layer?.backgroundColor = color(settings.options.background).cgColor
        }
        for label in [valueLabel, resetLabel, rateLabel, tokenLabel, observationLabel] + extraLabels {
            label.textColor = foreground
        }
        for button in [titleButton, foldButton, settingsButton] { button.contentTintColor = foreground }
    }
    private func providerFor(_ item: WindowItem) -> String? {
        ["claude", "antigravity", "cursor"].first { item.id.hasPrefix($0 + ":") }
    }
    private func sourceUpdate(for item: WindowItem) -> Date? {
        guard let provider = providerFor(item) else { return lastUpdate }
        return bridgeSnapshots[provider].map { Date(timeIntervalSince1970: $0.updatedAt) }
    }
    private func isStale(_ item: WindowItem, now: Double) -> Bool {
        guard let provider = providerFor(item) else { return stale }
        guard let snapshot = bridgeSnapshots[provider] else { return true }
        return now < snapshot.updatedAt || now - snapshot.updatedAt > 300
    }
    private func rebuildItems() {
        items = codexItems
        if settings.options.bridges {
            items += ["claude", "antigravity", "cursor"].flatMap { bridgeSnapshots[$0]?.limits.windows() ?? [] }
        }
        if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
    }
    private func reloadBridges() {
        guard settings.options.bridges else { return }
        var changed = false
        let now = Date().timeIntervalSince1970
        for provider in ["claude", "antigravity", "cursor"] {
            bridgeLastAttempt[provider] = now
            let path = support.appendingPathComponent("providers/" + provider + ".json")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                  let date = attrs[.modificationDate] as? Date else {
                markBridgeFailure(provider, code: "snapshotMissing"); continue
            }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? Int.max
            guard size <= 262144 else { markBridgeFailure(provider, code: "snapshotTooLarge"); continue }
            guard date != bridgeDates[provider] || bridgeLastError[provider] != nil else { continue }
            bridgeDates[provider] = date
            guard let bytes = try? Data(contentsOf: path) else { markBridgeFailure(provider, code: "snapshotUnreadable"); continue }
            guard let snapshot = try? JSONDecoder().decode(ProviderSnapshot.self, from: bytes),
                  snapshot.isValid(now: now, expectedProvider: provider),
                  snapshot.limits.windows().allSatisfy({ $0.id.hasPrefix(provider + ":") }) else {
                markBridgeFailure(provider, code: "snapshotInvalid"); continue
            }
            bridgeLastError[provider] = nil; bridgeFailureCounts[provider] = 0
            if snapshot.updatedAt == bridgeSnapshots[provider]?.updatedAt { continue }
            bridgeSnapshots[provider] = snapshot
            var history = bridgeHistories[provider] ?? History()
            history.record(account: snapshot.account, items: snapshot.limits.windows(), now: snapshot.updatedAt)
            bridgeHistories[provider] = history; changed = true
        }
        if changed { ratesDirty = true; rebuildItems(); resize(); screensChanged(); render(); writeStatus() }
        else { writeStatus() }
    }
    private func markBridgeFailure(_ provider: String, code: String) {
        bridgeLastError[provider] = code
        bridgeFailureCounts[provider, default: 0] += 1
    }
    private func setupPanel() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 128), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "QuotaPilot"
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovable = true; panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = pinned ? .floating : .normal
        panel.delegate = self
        let bg = CardBackground()
        bg.material = .hudWindow; bg.blendingMode = .behindWindow; bg.state = .active
        bg.wantsLayer = true; bg.layer?.cornerRadius = 14; bg.layer?.masksToBounds = true
        panel.contentView = bg
        colorOverlay.wantsLayer = true; colorOverlay.frame = bg.bounds
        colorOverlay.autoresizingMask = [.width, .height]
        bg.addSubview(colorOverlay)
        titleButton.isBordered = false; titleButton.alignment = .left
        titleButton.font = .systemFont(ofSize: 11, weight: .medium)
        titleButton.target = self; titleButton.action = #selector(selectWindow)
        titleButton.setAccessibilityLabel(l.text("selectWindow"))
        titleButton.toolTip = l.text("dragHint")
        foldButton.isBordered = false; foldButton.target = self; foldButton.action = #selector(toggleCollapsed)
        foldButton.setAccessibilityLabel(l.text("toggleCollapsed"))
        settingsButton.isBordered = false
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: l.text("settings"))
        settingsButton.target = self; settingsButton.action = #selector(openSettings)
        settingsButton.setAccessibilityLabel(l.text("settings"))
        settingsButton.toolTip = l.text("settings")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.alignment = .right
        resetLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rateLabel.font = .systemFont(ofSize: 10)
        rateLabel.textColor = .secondaryLabelColor
        tokenLabel.font = .systemFont(ofSize: 11)
        agentsLabel.font = .systemFont(ofSize: 11)
        observationLabel.font = .systemFont(ofSize: 9)
        observationLabel.textColor = .secondaryLabelColor
        for label in [valueLabel, resetLabel, rateLabel, tokenLabel, agentsLabel, observationLabel] { label.lineBreakMode = .byTruncatingTail }
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 100
        for view in [titleButton, foldButton, settingsButton, valueLabel, resetLabel, rateLabel, tokenLabel, agentsLabel, observationLabel, progress] { bg.addSubview(view) }
        resize()
        if defaults.object(forKey: "positionX") != nil {
            panel.setFrameOrigin(NSPoint(x: defaults.double(forKey: "positionX"), y: defaults.double(forKey: "positionY")))
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX-panel.frame.width-24, y: screen.visibleFrame.maxY-panel.frame.height-24))
        }
        screensChanged()
    }
    private func setupStatus() {
        if status == nil { status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        status.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "QuotaPilot")
        let menu = NSMenu()
        func add(_ name: String, _ action: Selector) {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        add(l.text("toggleVisible"), #selector(toggleVisible))
        add(l.text("refresh"), #selector(refresh))
        add(l.text(taskLedger.activeTask == nil ? "startTask" : "finishTask"), #selector(toggleTask))
        add(l.text("taskHistory"), #selector(showTaskHistory))
        add(l.text("exportTaskLedger"), #selector(exportTaskLedger))
        add(l.text("usageEventHistory"), #selector(showUsageEventHistory))
        add(l.text("exportUsageEvents"), #selector(exportUsageEvents))
        add(l.text("usageStats"), #selector(showStats))
        add(l.text("connectAgents"), #selector(connectAgents))
        add(l.text("agentCollaboration") + "…", #selector(configureCollaboration))
        add(l.text("sourceDiagnostics"), #selector(showSourceDiagnostics))
        add(l.text("toggleCollapsed"), #selector(toggleCollapsed))
        add(l.text("pin"), #selector(togglePinned))
        menu.items.last?.state = pinned ? .on : .off
        add(l.text("settings") + "…", #selector(openSettings))
        menu.addItem(.separator())
        add(l.text("quit"), #selector(quit))
        status.menu = menu
    }
    private func resize() {
        adjustingFrame = true
        defer { adjustingFrame = false }
        layoutStyled()
        let styled = !collapsed && cardStyle != .detailed
        for view in [valueLabel, progress, resetLabel, rateLabel, tokenLabel, agentsLabel, observationLabel] { view.isHidden = styled || collapsed }
        if styled {
            valueLabel.isHidden = true
            extraLabels.forEach { $0.removeFromSuperview() }; extraLabels = []
            applyColors(); foldButton.title = "−"; foldButton.toolTip = l.text("collapse")
            return
        }
        valueLabel.isHidden = false
        let old = panel.frame
        let size = collapsed ? NSSize(width: 182, height: 32) : NSSize(width: 260, height: 146 + CGFloat(extraGroups.count) * Self.extraRowHeight)
        panel.setFrame(NSRect(x: old.width == 300 ? old.maxX - size.width : old.minX, y: old.maxY-size.height, width: size.width, height: size.height), display: true)
        if collapsed {
            titleButton.frame = NSRect(x: 9, y: 6, width: 70, height: 20)
            valueLabel.frame = NSRect(x: 78, y: 6, width: 49, height: 20)
            settingsButton.frame = NSRect(x: 132, y: 6, width: 20, height: 20)
            foldButton.frame = NSRect(x: 158, y: 6, width: 18, height: 20)
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        } else {
            titleButton.frame = NSRect(x: 10, y: 119, width: 202, height: 20)
            settingsButton.frame = NSRect(x: 216, y: 119, width: 20, height: 20)
            foldButton.frame = NSRect(x: 238, y: 119, width: 18, height: 20)
            valueLabel.frame = NSRect(x: 167, y: 95, width: 78, height: 22)
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            progress.frame = NSRect(x: 12, y: 102, width: 143, height: 8)
            resetLabel.frame = NSRect(x: 12, y: 76, width: 236, height: 17)
            rateLabel.frame = NSRect(x: 12, y: 57, width: 236, height: 17)
            tokenLabel.frame = NSRect(x: 12, y: 39, width: 236, height: 17)
            agentsLabel.frame = NSRect(x: 12, y: 21, width: 236, height: 17)
            observationLabel.frame = NSRect(x: 12, y: 5, width: 236, height: 14)
        }
        extraLabels.forEach { $0.removeFromSuperview() }; extraLabels = []
        if !collapsed {
            let offset = CGFloat(extraGroups.count) * Self.extraRowHeight
            for view in [titleButton, settingsButton, foldButton, valueLabel, progress, resetLabel, rateLabel, tokenLabel, agentsLabel, observationLabel] {
                view.frame.origin.y += offset
            }
            for index in extraGroups.indices {
                let label = NSTextField(labelWithString: "")
                label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                label.lineBreakMode = .byTruncatingTail
                label.frame = NSRect(x: 12, y: CGFloat(extraGroups.count - index - 1) * Self.extraRowHeight + 4, width: 236, height: 14)
                extraLabels.append(label); panel.contentView?.addSubview(label)
            }
        }
        applyColors()
        foldButton.title = collapsed ? "⌄" : "−"
        foldButton.toolTip = l.text(collapsed ? "expand" : "collapse")
    }
    private func received(_ response: LimitsResponse, account: String) {
        codexItems = response.windows(); rebuildItems(); lastUpdate = Date()
        errorMessage = items.isEmpty ? "noQuota" : nil
        if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
        if tokenHistory.account != account { tokenAvailable = false }
        history.record(account: account, items: codexItems, now: Date().timeIntervalSince1970)
        checkAutoContinue(now: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: support.appendingPathComponent("history.json"), options: .atomic) }
        ratesDirty = true; resize(); render(); writeStatus()
    }
    private func title(for item: WindowItem) -> String {
        [item.name, item.planType?.capitalized, l.duration(item.window.windowDurationMins)].compactMap { $0 }.joined(separator: " · ")
    }
    private func rateText(_ rate: Rate?, metric: String, unavailable: Bool) -> String {
        let prefix = l.text(metric == "tokens" ? "accountTokens" : "quota")
        if unavailable { return prefix + " · —" }
        guard let rate else { return prefix + " · " + l.text("collecting") }
        let value = rate.value(per: settings.rateUnit)
        let number = metric == "tokens" ? l.compact(value) : l.rateNumber(value)
        let unit = metric == "tokens" ? "" : " " + l.text("points")
        return prefix + " · ≈" + number + unit + "/" + l.unit(settings.rateUnit, short: true)
    }
    private func render() {
        guard panel != nil else { return }
        let now = Date().timeIntervalSince1970
        let item = current
        titleButton.title = collapsed ? (item?.name ?? "Codex") : ((item.map { title(for: $0) } ?? "QuotaPilot") + " ▾")
        if let used = item?.window.usedPercent, used.isFinite, (0...100).contains(used) {
            valueLabel.stringValue = l.number(used, decimals: 0) + "%"
            progress.doubleValue = used
            valueLabel.textColor = stale ? .secondaryLabelColor : (used >= 90 ? .systemOrange : .labelColor)
        } else { valueLabel.stringValue = "—"; progress.doubleValue = 0 }
        if ratesDirty {
            cachedRates = [:]
            for window in items {
                let provider = providerFor(window)
                cachedRates[window.id] = (provider == nil ? history : bridgeHistories[provider!] ?? History()).rate(for: window.id, now: now, lookback: settings.lookback)
            }
            cachedTokenRate = tokenHistory.rate(now: now, lookback: settings.lookback)
            ratesDirty = false
        }
        let itemStale = item.map { isStale($0, now: now) } ?? stale
        let planRate = item.flatMap { cachedRates[$0.id] }
        let tokenRate = cachedTokenRate
        let tokenStale = !tokenAvailable || client.diagnostics.lastTokenSuccessAt.map { now - $0 > self.client.pollInterval + 30 } ?? true
        let sourceUpdated = item.flatMap { sourceUpdate(for: $0) }
        let sourceError = item.flatMap { providerFor($0) } == nil ? errorMessage : nil
        let planUnavailable = itemStale || item?.window.validUsedPercent == nil || (item?.window.resetsAt.map { $0 <= now } ?? false)
        resetLabel.stringValue = itemStale ? (sourceUpdated == nil ? l.text(sourceError ?? "connecting") : l.text("stale") + " · " + l.countdown(item?.window.resetsAt, now: now)) :
            (item.map { resetText($0, now: now) } ?? l.countdown(nil, now: now))
        rateLabel.stringValue = rateText(planRate, metric: "quota", unavailable: planUnavailable)
        tokenLabel.stringValue = "Codex · " + rateText(tokenRate, metric: "tokens", unavailable: tokenStale)
        let forecast = planUnavailable ? nil : forecastQuota(used: item?.window.validUsedPercent, perHour: planRate?.perHour, resetsAt: item?.window.resetsAt, now: now)
        rateLabel.textColor = planUnavailable ? .secondaryLabelColor : (forecast?.outlook == .exhausts ? .systemOrange : .labelColor)
        tokenLabel.textColor = tokenStale ? .secondaryLabelColor : .labelColor
        let partial = [planRate, tokenRate].compactMap { $0 }.contains { $0.observedSeconds < settings.lookback }
        observationLabel.stringValue = l.text("last") + " \(settings.intervalValue) " + l.unit(settings.intervalUnit, short: true) + (partial ? " · " + l.text("estimate") : "")
        let formatter = dateFormatter; formatter.locale = l.locale; formatter.dateStyle = .medium; formatter.timeStyle = .medium
        let resetDate = item?.window.resetsAt.map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? l.text("unknown")
        let updated = sourceUpdated.map { formatter.string(from: $0) } ?? l.text("unavailable")
        let sourceID = item.flatMap { providerFor($0).map { "bridge.\($0)" } } ?? "codex.quota"
        let selectedSource = sourceDiagnostics(now: now).first { $0.id == sourceID }
        let tokenSource = sourceDiagnostics(now: now).first { $0.id == "codex.accountTokens" }
        let sourceState = selectedSource.map { healthTitle($0.health) } ?? l.text("unavailable")
        let tokenFreshness = tokenSource.map { healthTitle($0.health) } ?? l.text("unavailable")
        let detail = "\(valueLabel.stringValue) · \(item.map { title(for: $0) } ?? "Codex")\n\(l.text("reset")): \(resetDate)\n\(rateLabel.stringValue)\n\(tokenLabel.stringValue)\n\(observationLabel.stringValue)\n\(l.text("updated")): \(updated) · \(sourceState) · \(diagnosticAge(selectedSource?.ageSeconds))\n\(l.text("sourceCodexTokens")): \(tokenFreshness) · \(diagnosticAge(tokenSource?.ageSeconds))" + (sourceError.map { "\n"+l.text($0) } ?? "")
        panel.contentView?.toolTip = detail; valueLabel.toolTip = detail; resetLabel.toolTip = detail
        rateLabel.toolTip = detail + forecastDetail(forecast, now: now) + "\n" + l.text("quotaHelp") + observedDetail(planRate)
        tokenLabel.toolTip = detail + "\n" + l.text("tokensHelp") + observedDetail(tokenRate)
        status?.button?.toolTip = detail
        for (index, group) in extraGroups.enumerated() where index < extraLabels.count {
            extraLabels[index].stringValue = compactLine(group, now: now)
            extraLabels[index].textColor = group.contains { ($0.window.validUsedPercent ?? 0) >= 90 } ? .systemOrange : .labelColor
            extraLabels[index].toolTip = group.map { extra -> String in
                let old = isStale(extra, now: now)
                let percent = extra.window.validUsedPercent.map { l.number($0, decimals: 0) + "%" } ?? "—"
                let rate = rateText(cachedRates[extra.id], metric: "quota", unavailable: old || extra.window.validUsedPercent == nil || (extra.window.resetsAt.map { $0 <= now } ?? false))
                return title(for: extra) + " · " + percent + "\n" + rate + "\n" + (old ? l.text("stale") + " · " : "") + resetText(extra, now: now)
            }.joined(separator: "\n\n") + "\n" + l.text("quotaHelp")
        }
        if cardStyle != .detailed && !collapsed && styledLines.count != providerGroups.count { resize() }
        renderStyled(now: now)
        checkQuotaAlerts(now: now)
        for window in items where !isStale(window, now: now) {
            statsStore.recordQuota(windowID: window.id, title: title(for: window), used: window.window.validUsedPercent, resetsAt: window.window.resetsAt, now: now)
        }
        renderAgentTokens(now: now)
        lastFreshness = items.map { isStale($0, now: now) || ($0.window.resetsAt.map { $0 <= now } ?? false) } + [stale, tokenStale]
        applyColors()
    }
    /// Notification delivery needs an app bundle; a bare `swift run` executable has none.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    private func requestAlertAuthorizationIfNeeded() {
        guard settings.quotaAlertsEnabled, notificationsAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // The widget is an agent app that is often frontmost; show alerts as banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func checkQuotaAlerts(now: Double) {
        guard settings.quotaAlertsEnabled, notificationsAvailable, !ratesDirty else { return }
        for item in ([current].compactMap { $0 } + extraItems) where !isStale(item, now: now) {
            let forecast = forecastQuota(used: item.window.validUsedPercent, perHour: cachedRates[item.id]?.perHour,
                                         resetsAt: item.window.resetsAt, now: now)
            for kind in quotaAlertTracker.alerts(windowID: item.id, used: item.window.validUsedPercent,
                                                 resetsAt: item.window.resetsAt, forecast: forecast) {
                let content = UNMutableNotificationContent()
                content.title = title(for: item)
                switch kind {
                case .highUsage:
                    content.body = l.number(item.window.validUsedPercent ?? 0, decimals: 0) + "% " + l.text("alertHighUsage") + " · " + l.text("reset") + " " + l.countdown(item.window.resetsAt, now: now)
                case .projectedExhaustion:
                    let eta = forecast?.exhaustsAt.map { l.countdown(max($0, now + 1), now: now) } ?? "—"
                    content.body = l.text("forecastFullIn") + " " + eta + " · " + l.text("alertBeforeReset")
                }
                let request = UNNotificationRequest(identifier: "quota.\(item.id).\(kind.rawValue)", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
            }
        }
    }

    private func resetText(_ item: WindowItem, now: Double) -> String {
        let countdown = (item.window.resetsAt.map { $0 > now } ?? false ? l.text("reset") + " " : "") + l.countdown(item.window.resetsAt, now: now)
        guard let used = item.window.validUsedPercent else { return countdown }
        return l.number(max(0, 100 - used), decimals: 0) + "% " + l.text("remaining") + " · " + countdown
    }

    // MARK: Local agent token logs

    private func scanAgentLogs() {
        guard settings.agentLogsEnabled else {
            agentLedger = AgentTokenLedger(); agentLastScanAt = nil; render(); return
        }
        guard !agentScanning else { return }
        agentScanning = true
        let now = Date().timeIntervalSince1970
        // Read at least five hours so switching to a short window still has data; at most the 31-day retention.
        let windowStart = now - min(max(settings.lookback, 5 * 3600), agentLedger.retention)
        let scanner = agentScanner
        agentScanQueue.async { [weak self] in
            let events = scanner.scan(windowStart: windowStart, now: now)
            DispatchQueue.main.async {
                guard let self else { return }
                self.agentScanning = false
                guard self.settings.agentLogsEnabled else { return }
                for event in events where self.agentLedger.add(event) { self.statsStore.add(event) }
                self.saveStats(now: now)
                self.agentLedger.prune(now: now)
                self.agentLastScanAt = now
                self.render(); self.writeStatus()
            }
        }
    }

    private func providerName(_ id: String) -> String {
        ["codex": "Codex", "claude": "Claude", "deepseek": "DeepSeek", "kimi": "Kimi", "glm": "GLM", "qwen": "Qwen",
         "minimax": "MiniMax", "gemini": "Gemini", "gpt": "GPT"][id] ?? id
    }

    private func breakdownText(_ b: TokenBreakdown) -> String {
        [l.text("tokenInput") + " " + l.compact(b.input),
         l.text("tokenCacheRead") + " " + l.compact(b.cacheRead),
         l.text("tokenCacheWrite") + " " + l.compact(b.cacheWrite),
         l.text("tokenOutput") + " " + l.compact(b.output) + (b.reasoning > 0 ? " (" + l.text("tokenReasoning") + " " + l.compact(b.reasoning) + ")" : "")]
            .joined(separator: " · ")
    }

    private func renderAgentTokens(now: Double) {
        guard settings.agentLogsEnabled else {
            agentsLabel.stringValue = l.text("allAgents") + " · " + l.text("agentLogsOff")
            agentsLabel.textColor = .secondaryLabelColor; agentsLabel.toolTip = l.text("agentLogsHelp"); return
        }
        guard agentLastScanAt != nil else {
            agentsLabel.stringValue = l.text("allAgents") + " · " + l.text("collecting")
            agentsLabel.textColor = .secondaryLabelColor; agentsLabel.toolTip = l.text("agentLogsHelp"); return
        }
        let since = now - settings.lookback
        let total = agentLedger.total(since: since, now: now)
        let perUnit = total.total / max(settings.lookback, 60) * settings.rateUnit.seconds
        let perProvider = agentLedger.summary(since: since, now: now).sorted { $0.value.total > $1.value.total }
            .prefix(3).map { providerName($0.key) + " " + l.compact($0.value.total) }
        agentsLabel.stringValue = l.text("allAgents") + " " + l.compact(total.total) + (perProvider.isEmpty ? "" : " · " + perProvider.joined(separator: " · "))
            + (deepSeekBalances.first.map { " · DS " + l.number($0.total, decimals: 2) + " " + $0.currency } ?? "")
        agentsLabel.textColor = .labelColor
        var lines = [l.text("allAgents") + " · " + observationLabel.stringValue,
                     l.text("tokenTotal") + " " + l.compact(total.total) + " · ≈" + l.compact(perUnit) + "/" + l.unit(settings.rateUnit, short: true),
                     breakdownText(total)]
        for (provider, usage) in agentLedger.summary(since: since, now: now).sorted(by: { $0.value.total > $1.value.total }) {
            lines.append(providerName(provider) + " " + l.compact(usage.total) + ": " + breakdownText(usage))
        }
        for balance in deepSeekBalances { lines.append(l.text("deepSeekBalance") + ": " + l.number(balance.total, decimals: 2) + " " + balance.currency) }
        if deepSeekError { lines.append(l.text("deepSeekError")) }
        let decision = routerDecision
        lines.append(l.text("suggestedAgent") + " (" + l.text("router." + (settings.routerMode ?? .auto).rawValue) + "): "
            + (decision.agent.map(providerName) ?? l.text("routerNone"))
            + " · " + decision.agents.map { providerName($0.provider) + " " + l.number($0.headroom, decimals: 0) + "%" }.joined(separator: " / "))
        lines.append(l.text("agentLogsHelp"))
        agentsLabel.toolTip = lines.joined(separator: "\n")
    }

    // MARK: Statistics

    private func saveStats(now: Double) {
        statsStore.prune(now: now)
        if let data = try? JSONEncoder().encode(statsStore) {
            let url = support.appendingPathComponent("usage-stats.json")
            if (try? data.write(to: url, options: .atomic)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        if statsWindow?.window?.isVisible == true { statsModel.store = statsStore; statsModel.language = settings.language }
    }

    /// One-time history: 30 days of agent token logs and the Codex quota checkpoints already in the event ledger.
    private func backfillStats() {
        let now = Date().timeIntervalSince1970
        if statsStore.quotaBackfilledAt == nil {
            for file in usageEventFiles() {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    guard let event = try? JSONDecoder().decode(UsageLedgerEvent.self, from: Data(line.utf8)),
                          event.kind == .checkpoint, let observation = event.observation else { continue }
                    for window in observation.quotaWindows {
                        let title = window.name + " · " + l.duration(window.windowDurationMins)
                        statsStore.recordQuota(windowID: window.id, title: title, used: window.usedPercent, resetsAt: window.resetsAt, now: observation.capturedAt)
                    }
                }
            }
            statsStore.finishQuotaBackfill(at: now)
        }
        guard settings.agentLogsEnabled, statsStore.backfilledAt == nil else { return }
        statsModel.backfilling = true
        let scanner = AgentLogScanner(sources: AgentLogScanner.defaultSources(home: FileManager.default.homeDirectoryForCurrentUser))
        // Separate queue: the regular one-minute scans keep running while the long backfill reads.
        // .utility, not .background: background QoS throttles disk reads heavily, which made a 30-day backfill take hours.
        let done = statsStore.backfilledFiles ?? []
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let windowStart = now - 30 * 86400
            // File by file, saving progress, so quitting the app does not lose what was already read.
            var lastSave = Date()
            for file in scanner.backfillCandidates(windowStart: windowStart) where !done.contains(file.path) {
                let events = scanner.backfillFile(file.path, source: file.source, windowStart: windowStart)
                let save = Date().timeIntervalSince(lastSave) > 30
                if save { lastSave = Date() }
                DispatchQueue.main.sync {
                    guard let self else { return }
                    for event in events { self.statsStore.add(event) }
                    self.statsStore.markBackfilled(file: file.path)
                    if save { self.saveStats(now: Date().timeIntervalSince1970) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statsStore.finishBackfill(at: now)
                self.statsModel.backfilling = false
                self.saveStats(now: Date().timeIntervalSince1970)
            }
        }
    }

    @objc private func showStats() {
        statsModel.store = statsStore
        statsModel.language = settings.language
        if statsWindow == nil { statsWindow = StatsWindowController(model: statsModel, title: "QuotaPilot · " + l.text("usageStats").replacingOccurrences(of: "…", with: "")) }
        statsWindow?.present()
    }

    // MARK: Connections

    private func refreshDeepSeek() {
        guard let key = settings.autoConnectEnabled ? AgentDetection.deepSeekKey() : KeychainSecret.read("deepseek") else {
            deepSeekBalances = []; deepSeekError = false; return
        }
        var request = URLRequest(url: DeepSeekBalance.endpoint, timeoutInterval: 20)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let parsed = ok ? data.flatMap(DeepSeekBalance.parse) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.deepSeekBalances = parsed?.balances ?? []
                self.deepSeekError = parsed == nil
                self.render(); self.writeStatus()
            }
        }.resume()
    }

    @objc private func connectAgents() {
        NSApp.activate(ignoringOtherApps: true)
        func state(_ installed: Bool, _ connected: Bool) -> String {
            installed ? l.text(connected ? "connected" : "notConnected") : l.text("notInstalled")
        }
        let claudeBridge = AgentDetection.bridgeInstalled("claude"), antigravityBridge = AgentDetection.bridgeInstalled("antigravity")
        let tokens = settings.agentLogsEnabled ? l.text("agentTokensAuto") : l.text("agentLogsOff")
        let lines = [
            "Codex: " + l.text(client.executable == nil ? "notInstalled" : "connected") + " · " + tokens,
            "Claude Code: " + tokens + " · " + l.text("agentQuotaBridge") + " " + state(AgentDetection.claudeInstalled, claudeBridge),
            "Antigravity CLI: " + l.text("agentQuotaBridge") + " " + state(AgentDetection.antigravityInstalled, antigravityBridge),
            "DeepSeek: " + l.text(AgentDetection.deepSeekKey() == nil ? "notConnected" : "connected") + " — " + l.text("deepSeekNote"),
            l.text("cursorNote")
        ]
        let alert = NSAlert()
        alert.messageText = l.text("connectAgentsTitle")
        alert.informativeText = lines.joined(separator: "\n\n")
        var actions: [() -> Void] = []
        if AgentDetection.claudeInstalled && !claudeBridge {
            alert.addButton(withTitle: l.text("connectClaude")); actions.append { [weak self] in self?.installBridge("claude") }
        }
        if AgentDetection.antigravityInstalled && !antigravityBridge {
            alert.addButton(withTitle: l.text("connectAntigravity")); actions.append { [weak self] in self?.installBridge("antigravity") }
        }
        alert.addButton(withTitle: l.text("deepSeekKey")); actions.append { [weak self] in self?.editDeepSeekKey() }
        alert.addButton(withTitle: l.text("agentCollaboration")); actions.append { [weak self] in self?.configureCollaboration() }
        alert.addButton(withTitle: l.text("done")); actions.append {}
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if actions.indices.contains(index) { actions[index]() }
    }

    /// Connects whatever can be connected without asking: bridges whose status line is free or a command,
    /// provider imports once a snapshot exists, and the DeepSeek balance when a key is configured.
    private func autoConnectAgents() {
        guard settings.autoConnectEnabled else { return }
        let pending = AgentDetection.pendingBridges()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let results = pending.map { ($0, AgentDetection.installBridge($0)) }
            DispatchQueue.main.async {
                guard let self else { return }
                for (provider, result) in results { self.autoConnectResults[provider] = result.ok ? "connected" : "failed" }
                let snapshots = ["claude", "antigravity", "cursor"].contains {
                    FileManager.default.fileExists(atPath: support.appendingPathComponent("providers/\($0).json").path)
                }
                if !self.settings.options.bridges && (snapshots || results.contains { $0.1.ok } || AgentDetection.bridgeInstalled("claude") || AgentDetection.bridgeInstalled("antigravity")) {
                    var next = self.settings
                    var options = next.options; options.bridges = true; next.options = options
                    self.settings = next
                    self.defaults.set(try? JSONEncoder().encode(next), forKey: "settings")
                }
                self.reloadBridges(); self.rebuildItems(); self.refreshDeepSeek(); self.writeStatus()
            }
        }
    }

    /// Claude Pro/Max usage via Claude Code's login, so it works for the desktop app and remote sessions
    /// where no status line runs. Writes the same sanitized snapshot the status-line bridge writes.
    private func refreshClaudePlan() {
        guard settings.autoConnectEnabled, AgentDetection.claudeInstalled, !claudePlanFetching else { return }
        claudePlanFetching = true
        // The first keychain read can wait on a macOS permission prompt, so keep it off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let login = KeychainSecret.claudeCodeCredentials().flatMap(ClaudePlanUsage.credentials)
            DispatchQueue.main.async { self?.fetchClaudePlan(login: login) }
        }
    }

    private func fetchClaudePlan(login: (token: String, plan: String?, expiresAt: Double?)?) {
        guard let login else { claudePlanFetching = false; claudePlanError = "claudeLoginMissing"; return }
        if let expires = login.expiresAt, expires <= Date().timeIntervalSince1970 {
            claudePlanFetching = false; claudePlanError = "claudeLoginExpired"; return
        }
        var request = URLRequest(url: ClaudePlanUsage.endpoint, timeoutInterval: 20)
        request.setValue("Bearer " + login.token, forHTTPHeaderField: "Authorization")
        request.setValue(ClaudePlanUsage.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] body, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snapshot = (200..<300).contains(status) ? body.flatMap { ClaudePlanUsage.snapshot(from: $0, plan: login.plan, now: Date().timeIntervalSince1970) } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.claudePlanFetching = false
                guard let snapshot, let encoded = try? JSONEncoder().encode(snapshot) else {
                    self.claudePlanError = status == 401 ? "claudeLoginExpired" : "claudePlanUnavailable"; self.writeStatus(); return
                }
                self.claudePlanError = nil
                let directory = support.appendingPathComponent("providers", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let path = directory.appendingPathComponent("claude.json")
                if (try? encoded.write(to: path, options: .atomic)) != nil {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                    // Tells the status-line bridge not to replace this account-level snapshot with a session-level one.
                    FileManager.default.createFile(atPath: directory.appendingPathComponent("claude-plan.active").path, contents: Data(), attributes: [.posixPermissions: 0o600])
                }
                self.enableProviderRowsOnce(provider: "claude", windows: snapshot.limits.windows().map(\.id))
                self.reloadBridges()
            }
        }.resume()
    }

    /// The first time a provider connects automatically, show its windows on the card next to Codex.
    private func enableProviderRowsOnce(provider: String, windows: [String]) {
        let key = "autoAddedRows." + provider
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        var next = settings
        var options = next.options
        options.bridges = true
        if !options.multiple { options.multiple = true; options.windowIDs = [] }
        for id in windows.sorted() where !options.windowIDs.contains(id) && options.windowIDs.count < 4 { options.windowIDs.append(id) }
        next.options = options
        settings = next
        defaults.set(try? JSONEncoder().encode(next), forKey: "settings")
        rebuildItems(); resize(); render()
    }

    private var routerDecision: RouterDecision {
        AgentRouter.decide(mode: settings.routerMode ?? .auto, items: items, now: Date().timeIntervalSince1970)
    }

    @objc private func configureCollaboration() {
        NSApp.activate(ignoringOtherApps: true)
        guard let codex = client.executable else { showMessage(title: l.text("sourceError"), details: "Codex CLI not found"); return }
        let links = AgentCollaboration.Link.allCases
        let current = Dictionary(uniqueKeysWithValues: links.map { ($0, AgentCollaboration.isEnabled($0, codex: codex)) })
        let alert = NSAlert()
        alert.messageText = l.text("agentCollaboration")
        alert.informativeText = l.text("collaborationIntro")
        let boxes = links.map { link -> NSButton in
            let box = NSButton(checkboxWithTitle: l.text("link." + link.rawValue), target: nil, action: nil)
            box.state = current[link] == true ? .on : .off
            box.isEnabled = AgentDetection.claudeInstalled
            return box
        }
        let modeLabel = NSTextField(labelWithString: l.text("routerMode"))
        let modes = NSPopUpButton(frame: .zero, pullsDown: false)
        modes.addItems(withTitles: RouterMode.allCases.map { l.text("router." + $0.rawValue) })
        modes.selectItem(at: RouterMode.allCases.firstIndex(of: settings.routerMode ?? .auto) ?? 0)
        let modeRow = NSStackView(views: [modeLabel, modes])
        let ruleMenus = TaskKind.allCases.map { kind -> NSPopUpButton in
            let menu = NSPopUpButton(frame: .zero, pullsDown: false)
            menu.addItems(withTitles: TaskAssignee.allCases.map { $0 == .auto ? l.text("router.auto") : ($0 == .codex ? "Codex" : "Claude") })
            menu.selectItem(at: TaskAssignee.allCases.firstIndex(of: settings.taskRouting[kind] ?? .auto) ?? 0)
            return menu
        }
        let ruleRows = zip(TaskKind.allCases, ruleMenus).map { kind, menu in
            NSStackView(views: [NSTextField(labelWithString: l.text("task." + kind.rawValue)), menu])
        }
        let rulesTitle = NSTextField(labelWithString: l.text("taskRules"))
        rulesTitle.font = .boldSystemFont(ofSize: 11)
        let stack = NSStackView(views: boxes + [modeRow, rulesTitle] + ruleRows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.frame = NSRect(x: 0, y: 0, width: 560, height: 300)
        alert.accessoryView = stack
        alert.addButton(withTitle: l.text("apply")); alert.addButton(withTitle: l.text("cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var next = settings
        next.routerMode = RouterMode.allCases[modes.indexOfSelectedItem]
        next.taskRouting = Dictionary(uniqueKeysWithValues: zip(TaskKind.allCases, ruleMenus).map { ($0, TaskAssignee.allCases[$1.indexOfSelectedItem]) })
        settings = next
        defaults.set(try? JSONEncoder().encode(next), forKey: "settings")
        var results: [String] = []
        for (link, box) in zip(links, boxes) where (box.state == .on) != current[link] {
            let r = AgentCollaboration.set(link, enabled: box.state == .on, codex: codex)
            results.append(l.text("link." + link.rawValue) + ": " + (r.ok ? "✓" : "✗ " + r.output))
        }
        render(); writeStatus()
        if !results.isEmpty { showMessage(title: l.text("agentCollaboration"), details: results.joined(separator: "\n") + "\n\n" + l.text("collaborationRestart")) }
    }

    private func installBridge(_ provider: String) {
        let result = AgentDetection.installBridge(provider)
        if result.ok {
            var next = settings
            var options = next.options; options.bridges = true; next.options = options
            settings = next
            defaults.set(try? JSONEncoder().encode(next), forKey: "settings")
            reloadBridges(); rebuildItems()
        }
        showMessage(title: result.ok ? l.text("bridgeInstalledRestart") : l.text("sourceError"), details: result.output)
    }

    private func editDeepSeekKey() {
        let alert = NSAlert()
        alert.messageText = l.text("deepSeekKey")
        alert.informativeText = l.text("deepSeekKeyPrompt")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: l.text("apply")); alert.addButton(withTitle: l.text("cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        KeychainSecret.write("deepseek", value: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshDeepSeek(); render()
    }

    // MARK: Auto-continue

    private func checkAutoContinue(now: Double) {
        var action = AutoContinuePlanner.Action.none
        for item in codexItems {
            let result = autoContinuePlanner.observe(windowID: item.id, used: item.window.validUsedPercent, limitReached: item.limitReached, now: now)
            if case .resume = result { action = result }
        }
        guard settings.autoContinueEnabled, case .resume(let blockedSince) = action, !autoContinueRunning,
              let executable = client.executable else { return }
        autoContinueRunning = true
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
        let logURL = support.appendingPathComponent("auto-continue.log")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let session = CodexSessionLocator.interruptedSession(root: root, blockedSince: blockedSince, now: now)
            var result = "noSession"
            if let session {
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["exec", "resume", session.id, autoContinueDefaultPrompt]
                process.currentDirectoryURL = URL(fileURLWithPath: session.cwd)
                process.standardInput = FileHandle.nullDevice
                if let log = try? FileHandle(forWritingTo: logURL) {
                    _ = try? log.seekToEnd()
                    log.write(Data("\n=== \(Date()) resume \(session.id) in \(session.cwd)\n".utf8))
                    process.standardOutput = log; process.standardError = log
                }
                do { try process.run(); result = "started" } catch { result = "launchFailed" }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.autoContinueRunning = false
                self.lastAutoContinue = (now, session?.id, result)
                self.notifyAutoContinue(result: result, cwd: session?.cwd)
                self.writeStatus()
            }
        }
    }

    private func notifyAutoContinue(result: String, cwd: String?) {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = l.text("autoContinue")
        content.body = l.text(result == "started" ? "autoContinueStarted" : "autoContinueSkipped") + (cwd.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "autoContinue.\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    private func forecastDetail(_ forecast: QuotaForecast?, now: Double) -> String {
        guard let forecast else { return "" }
        let value = forecast.exhaustsAt.map { l.text("forecastFullIn") + " " + l.countdown($0 > now ? $0 : now + 1, now: now) }
            ?? ("≈" + l.number(forecast.projectedUsedAtReset, decimals: 0) + "% " + l.text("forecastAtReset"))
        return "\n" + l.text("paceForecast") + ": " + value + "\n" + l.text("forecastHelp")
    }
    private func observedDetail(_ rate: Rate?) -> String {
        guard let rate else { return "" }
        return "\n" + l.text("observed") + ": " + l.number(rate.observedSeconds/60, decimals: 0) + " " + l.unit(.minute)
    }
    @objc private func openSettings() {
        if let window = settingsWindow, window.window?.isVisible == true { window.present(); return }
        settingsWindow = SettingsWindowController(settings: settings, windows: items.map { ($0.id, title(for: $0)) }) { [weak self] next in
            guard let self else { return }
            self.settings = next
            self.ratesDirty = true
            self.requestAlertAuthorizationIfNeeded()
            self.scanAgentLogs(); self.autoConnectAgents()
            self.client.pollInterval = next.options.energySaver ? 120 : 60
            self.startUITimer(); self.reloadBridges(); self.rebuildItems()
            self.defaults.set(try? JSONEncoder().encode(next), forKey: "settings")
            self.titleButton.setAccessibilityLabel(self.l.text("selectWindow"))
            self.titleButton.toolTip = self.l.text("dragHint")
            self.foldButton.setAccessibilityLabel(self.l.text("toggleCollapsed"))
            self.settingsButton.setAccessibilityLabel(self.l.text("settings"))
            self.settingsButton.toolTip = self.l.text("settings")
            self.resize(); self.setupStatus(); self.render(); self.writeStatus()
        }
        settingsWindow?.openTool = { [weak self] tool in
            switch tool {
            case "agentCollaboration": self?.configureCollaboration()
            case "connectAgents": self?.connectAgents()
            default: self?.showStats()
            }
        }
        settingsWindow?.present()
    }

    private func currentSourceHealth(lastSuccess: Double?, staleAfter: Double, now: Double,
                                     enabled: Bool = true, error: String? = nil) -> SourceHealth {
        sourceHealth(lastSuccessAt: lastSuccess, now: now, staleAfterSeconds: staleAfter,
                     enabled: enabled, paused: client.diagnostics.suspended, errorCode: error)
    }

    private func currentTokenSourceHealth(_ state: ClientDiagnostics, now: Double,
                                          staleAfter: Double) -> SourceHealth {
        guard !state.suspended else { return .paused }
        guard let account = history.account else { return .unavailable }
        if state.lastTokenAttemptAccountKey == account, state.lastTokenErrorCode != nil { return .error }
        guard tokenAvailable, tokenHistory.account == account,
              state.lastTokenSuccessAccountKey == account,
              let successAt = state.lastTokenSuccessAt else { return .unavailable }
        return sourceHealth(lastSuccessAt: successAt, now: now, staleAfterSeconds: staleAfter)
    }

    private func sourceDiagnostics(now: Double = Date().timeIntervalSince1970) -> [SourceDiagnostic] {
        let clientState = client.diagnostics
        let staleAfter = client.pollInterval + 30
        let quotaAge = clientState.lastQuotaSuccessAt.map { max(0, now - $0) }
        let tokenSuccessMatchesAccount = history.account != nil && clientState.lastTokenSuccessAccountKey == history.account
        let tokenAttemptMatchesAccount = history.account != nil && clientState.lastTokenAttemptAccountKey == history.account
        let tokenSuccessAt = tokenSuccessMatchesAccount ? clientState.lastTokenSuccessAt : nil
        let tokenAttemptAt = tokenAttemptMatchesAccount ? clientState.lastTokenAttemptAt : nil
        let tokenError = tokenAttemptMatchesAccount ? clientState.lastTokenErrorCode : nil
        let tokenAge = tokenSuccessAt.map { max(0, now - $0) }
        let quota = SourceDiagnostic(id: "codex.quota",
                                     health: currentSourceHealth(lastSuccess: clientState.lastQuotaSuccessAt,
                                                                 staleAfter: staleAfter, now: now,
                                                                 error: clientState.lastFailureCode),
                                     lastAttemptAt: clientState.lastAttemptAt,
                                     lastSuccessAt: clientState.lastQuotaSuccessAt,
                                     ageSeconds: quotaAge, staleAfterSeconds: staleAfter,
                                     lastErrorCode: clientState.lastFailureCode,
                                     consecutiveFailures: clientState.consecutiveFailures,
                                     nextAttemptAt: clientState.nextAttemptAt)
        let tokens = SourceDiagnostic(id: "codex.accountTokens",
                                      health: currentTokenSourceHealth(clientState, now: now, staleAfter: staleAfter),
                                      lastAttemptAt: tokenAttemptAt,
                                      lastSuccessAt: tokenSuccessAt,
                                      ageSeconds: tokenAge, staleAfterSeconds: staleAfter,
                                      lastErrorCode: tokenError,
                                      consecutiveFailures: tokenAttemptMatchesAccount ? clientState.consecutiveTokenFailures : 0,
                                      nextAttemptAt: clientState.nextAttemptAt)
        func bridge(_ provider: String) -> SourceDiagnostic {
            let snapshot = bridgeSnapshots[provider]
            let updated = snapshot?.updatedAt
            return SourceDiagnostic(id: "bridge.\(provider)",
                                    health: currentSourceHealth(lastSuccess: updated, staleAfter: 300,
                                                                now: now, enabled: settings.options.bridges,
                                                                error: bridgeLastError[provider]),
                                    enabled: settings.options.bridges,
                                    lastAttemptAt: bridgeLastAttempt[provider], lastSuccessAt: updated,
                                    ageSeconds: updated.map { max(0, now - $0) }, staleAfterSeconds: 300,
                                    lastErrorCode: bridgeLastError[provider],
                                    consecutiveFailures: bridgeFailureCounts[provider] ?? 0)
        }
        let eventStore = SourceDiagnostic(id: "local.usageEventLedger",
                                          health: sourceHealth(lastSuccessAt: usageEventLastSuccessAt,
                                                               now: now, staleAfterSeconds: 300,
                                                               errorCode: usageEventLastErrorCode),
                                          lastAttemptAt: usageEventLastAttemptAt,
                                          lastSuccessAt: usageEventLastSuccessAt,
                                          ageSeconds: usageEventLastSuccessAt.map { max(0, now - $0) },
                                          staleAfterSeconds: 300,
                                          lastErrorCode: usageEventLastErrorCode,
                                          consecutiveFailures: usageEventConsecutiveFailures)
        return [quota, tokens, bridge("claude"), bridge("antigravity"), bridge("cursor"), eventStore]
    }

    private func sourceTitle(_ id: String) -> String {
        switch id {
        case "codex.quota": return l.text("sourceCodexQuota")
        case "codex.accountTokens": return l.text("sourceCodexTokens")
        case "bridge.claude": return l.text("sourceClaude")
        case "bridge.antigravity": return l.text("sourceAntigravity")
        case "bridge.cursor": return l.text("sourceCursor")
        case "local.usageEventLedger": return l.text("sourceUsageEventLedger")
        default: return id
        }
    }

    private func healthTitle(_ health: SourceHealth) -> String {
        switch health {
        case .fresh: return l.text("sourceFresh")
        case .stale: return l.text("stale")
        case .unavailable: return l.text("unavailable")
        case .error: return l.text("sourceError")
        case .paused: return l.text("sourcePaused")
        case .disabled: return l.text("sourceDisabled")
        }
    }

    private func diagnosticAge(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return l.text("never") }
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m \(Int(seconds) % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func diagnosticsText(now: Double = Date().timeIntervalSince1970) -> String {
        let formatter = DateFormatter()
        formatter.locale = l.locale; formatter.dateStyle = .short; formatter.timeStyle = .short
        func date(_ value: Double?) -> String {
            guard let value, value.isFinite else { return l.text("never") }
            return formatter.string(from: Date(timeIntervalSince1970: value))
        }
        var lines = [l.text("sourceDiagnosticIntro"), ""]
        for source in sourceDiagnostics(now: now) {
            lines.append("\(sourceTitle(source.id)) · \(healthTitle(source.health))")
            lines.append("\(l.text("dataAge")): \(diagnosticAge(source.ageSeconds)) (\(l.text("staleAfter")) \(diagnosticAge(source.staleAfterSeconds)))")
            lines.append("\(l.text("lastAttempt")): \(date(source.lastAttemptAt)) · \(l.text("lastSuccess")): \(date(source.lastSuccessAt))")
            var status = [String]()
            if let next = source.nextAttemptAt { status.append("\(l.text("nextAttempt")): \(date(next))") }
            if source.consecutiveFailures > 0 { status.append("\(l.text("failureCount")): \(source.consecutiveFailures)") }
            if let code = source.lastErrorCode { status.append("\(l.text("errorCode")): \(l.text(code) == code ? code : l.text(code))") }
            if !status.isEmpty { lines.append(status.joined(separator: " · ")) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func makeAccountSnapshot(now: Double = Date().timeIntervalSince1970) -> AccountUsageSnapshot {
        let clientState = client.diagnostics
        let staleAfter = client.pollInterval + 30
        let quotaHealth = currentSourceHealth(lastSuccess: clientState.lastQuotaSuccessAt,
                                              staleAfter: staleAfter, now: now,
                                              error: clientState.lastFailureCode)
        let tokenHealth = currentTokenSourceHealth(clientState, now: now, staleAfter: staleAfter)
        let windows = codexItems.compactMap { item -> ObservedQuotaWindow? in
            guard let used = item.window.validUsedPercent else { return nil }
            return ObservedQuotaWindow(id: item.id, name: item.name, usedPercent: used,
                                       windowDurationMins: item.window.windowDurationMins,
                                       resetsAt: item.window.resetsAt)
        }
        let tokenTotal = tokenAvailable && tokenHistory.account == history.account &&
            clientState.lastTokenSuccessAccountKey == history.account
            ? tokenHistory.samples.last?.total : nil
        let tokenObservedAt = clientState.lastTokenSuccessAccountKey == history.account
            ? clientState.lastTokenSuccessAt : nil
        return AccountUsageSnapshot(capturedAt: now, accountKey: history.account,
                                    quotaObservedAt: clientState.lastQuotaSuccessAt,
                                    quotaHealth: quotaHealth, quotaWindows: windows,
                                    accountTokenTotal: tokenTotal,
                                    tokenObservedAt: tokenObservedAt,
                                    tokenHealth: tokenHealth)
    }

    /// Decodes a ledger file. An unreadable file is moved aside instead of being overwritten by an empty ledger on the next save.
    private func loadPrivateLedger<T: Decodable>(_ type: T.Type, named name: String) -> T? {
        let url = support.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(type, from: data) { return saved }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = support.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".corrupt-\(stamp)." + url.pathExtension)
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
    }

    @discardableResult
    private func saveTaskData() -> Bool {
        var saved = true
        let files: [(String, Data?)] = [
            ("task-ledger.json", try? JSONEncoder().encode(taskLedger)),
            ("account-observations.json", try? JSONEncoder().encode(accountObservations))
        ]
        for (name, data) in files {
            guard let data else { saved = false; continue }
            let url = support.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { saved = false }
        }
        return saved
    }

    private func appendBoundarySnapshot() -> String {
        let snapshot = makeAccountSnapshot()
        accountObservations.append(snapshot)
        return snapshot.id
    }

    private func loadUsageEventLedger() {
        let stateURL = support.appendingPathComponent("usage-event-state.json")
        let stateFileExists = FileManager.default.fileExists(atPath: stateURL.path)
        let savedState = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(UsageEventLedgerState.self, from: $0) }
        var state = savedState ?? UsageEventLedgerState()
        let eventsURL = support.appendingPathComponent("usage-events.jsonl")
        let eventsFileExists = FileManager.default.fileExists(atPath: eventsURL.path)
        let recent = readRecentUsageEvents(from: eventsURL, limit: UsageEventLedger.recentEventLimit)
        if let checkpoint = recent.last(where: { $0.kind == .checkpoint })?.observation,
           state.latestObservation == nil || checkpoint.capturedAt > (state.latestObservation?.capturedAt ?? -.infinity) {
            state.latestObservation = checkpoint
            state.lastCheckpointAt = checkpoint.capturedAt
            state.lastCheckpointObservation = checkpoint
        }
        usageEventLedger = UsageEventLedger(state: state, recentEvents: recent)
        let eventFileAttributes = try? FileManager.default.attributesOfItem(atPath: eventsURL.path)
        let eventFileSize = (eventFileAttributes?[.size] as? NSNumber)?.intValue ?? 0
        if stateFileExists, savedState != nil, savedState?.eventCount ?? 0 > 0,
           !eventsFileExists || eventFileSize == 0 {
            usageEventIntegrityErrorCode = "eventLogMissing"
            usageEventLastErrorCode = usageEventIntegrityErrorCode
            usageEventConsecutiveFailures = 1
        } else if !stateFileExists, eventsFileExists {
            usageEventLastErrorCode = "eventStateMissing"
            usageEventConsecutiveFailures = 1
        }
        if stateFileExists {
            if savedState != nil,
               let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
               let modifiedAt = attributes[.modificationDate] as? Date {
                usageEventLastSuccessAt = modifiedAt.timeIntervalSince1970
                usageEventLastAttemptAt = modifiedAt.timeIntervalSince1970
            } else {
                usageEventLastErrorCode = usageEventIntegrityErrorCode ?? "eventStateUnreadable"
                usageEventConsecutiveFailures = 1
            }
        } else {
            usageEventLastSuccessAt = nil
        }
    }

    private func readRecentUsageEvents(from url: URL, limit: Int) -> [UsageLedgerEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        var offset = end
        var data = Data()
        var newlineCount = 0
        while offset > 0 && newlineCount <= limit {
            let count = min(UInt64(64 * 1024), offset)
            offset -= count
            guard (try? handle.seek(toOffset: offset)) != nil else { return [] }
            let chunk: Data
            do {
                guard let bytes = try handle.read(upToCount: Int(count)) else { return [] }
                chunk = bytes
            } catch { return [] }
            newlineCount += chunk.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            data.insert(contentsOf: chunk, at: 0)
        }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        return lines.suffix(limit).compactMap { line in
            try? JSONDecoder().decode(UsageLedgerEvent.self, from: Data(line))
        }
    }

    private func recordUsageObservation(account: String, tokenTotal: Double?, now: Double) {
        guard history.account == account else {
            recordUsageFailure(sourceID: "codex.account", errorCode: "accountIdentityMismatch",
                               accountKey: account, now: now)
            return
        }
        let state = client.diagnostics
        let windows = codexItems.map { item in
            UsageLedgerWindow(id: item.id, name: item.name,
                              usedPercent: item.window.validUsedPercent,
                              windowDurationMins: item.window.windowDurationMins,
                              resetsAt: item.window.resetsAt)
        }
        let tokenMatchesAccount = tokenAvailable && tokenHistory.account == account &&
            state.lastTokenSuccessAccountKey == account
        let tokenError = state.lastTokenAttemptAccountKey == account ? state.lastTokenErrorCode : nil
        let tokenHealth = currentTokenSourceHealth(state, now: now, staleAfter: client.pollInterval + 30)
        let observation = UsageLedgerObservation(capturedAt: state.lastQuotaSuccessAt ?? now,
                                                 accountKey: account, quotaWindows: windows,
                                                 quotaHealth: currentSourceHealth(lastSuccess: state.lastQuotaSuccessAt,
                                                                                  staleAfter: client.pollInterval + 30,
                                                                                  now: now, error: state.lastFailureCode),
                                                 quotaErrorCode: state.lastFailureCode,
                                                 accountTokenTotal: tokenMatchesAccount ? tokenTotal : nil,
                                                 tokenObservedAt: tokenMatchesAccount ? state.lastTokenSuccessAt : nil,
                                                 tokenHealth: tokenHealth, tokenErrorCode: tokenError)
        let events = usageEventLedger.observe(observation)
        persistUsageEventChanges(events, now: now)
    }

    private func recordUsageFailure(sourceID: String, errorCode: String, accountKey: String?, now: Double) {
        let events = usageEventLedger.recordFailure(sourceID: sourceID, timestamp: now,
                                                    accountKey: accountKey, errorCode: errorCode)
        persistUsageEventChanges(events, now: now)
    }

    private func persistUsageEventChanges(_ events: [UsageLedgerEvent], now: Double) {
        usageEventLastAttemptAt = now
        pendingUsageEventWrites.append(contentsOf: events)
        if pendingUsageEventWrites.count > maxPendingUsageEventWrites {
            pendingUsageEventWrites.removeFirst(pendingUsageEventWrites.count - maxPendingUsageEventWrites)
        }
        var succeeded = true
        do { try appendPendingUsageEvents() }
        catch { succeeded = false; markUsageEventPersistenceFailure("eventAppendFailed") }
        do { try saveUsageEventState() }
        catch { succeeded = false; markUsageEventPersistenceFailure("eventStateWriteFailed") }
        if succeeded {
            usageEventLastErrorCode = usageEventIntegrityErrorCode
            usageEventConsecutiveFailures = usageEventIntegrityErrorCode == nil ? 0 : 1
            usageEventLastSuccessAt = now
        }
    }

    private func appendPendingUsageEvents() throws {
        guard !pendingUsageEventWrites.isEmpty else { return }
        let url = support.appendingPathComponent("usage-events.jsonl")
        var data = Data()
        let encoder = JSONEncoder()
        for event in pendingUsageEventWrites {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        rotateUsageEventFileIfNeeded(url)
        if !FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let originalSize = try handle.seekToEnd()
        // Terminate a line left partial by an interrupted earlier write so the next event stays decodable.
        if originalSize > 0 {
            try handle.seek(toOffset: originalSize - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { data.insert(0x0A, at: 0) }
            try handle.seek(toOffset: originalSize)
        }
        do { try handle.write(contentsOf: data) }
        catch { try? handle.truncate(atOffset: originalSize); throw error }
        pendingUsageEventWrites.removeAll(keepingCapacity: true)
        try handle.synchronize()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Archives a large event log as `usage-events-<UTC time>.jsonl`; nothing is deleted.
    private func rotateUsageEventFileIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
              size >= usageEventFileRotationBytes else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let archive = support.appendingPathComponent("usage-events-\(formatter.string(from: Date())).jsonl")
        guard !FileManager.default.fileExists(atPath: archive.path) else { return }
        try? FileManager.default.moveItem(at: url, to: archive)
    }

    /// Archived event logs oldest first, followed by the active log.
    private func usageEventFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        let archives = names.filter { $0.hasPrefix("usage-events-") && $0.hasSuffix(".jsonl") }.sorted()
        return (archives + ["usage-events.jsonl"]).map { support.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func saveUsageEventState() throws {
        let url = support.appendingPathComponent("usage-event-state.json")
        let data = try JSONEncoder().encode(usageEventLedger.state)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func markUsageEventPersistenceFailure(_ code: String) {
        usageEventLastErrorCode = code
        usageEventConsecutiveFailures += 1
    }

    @objc private func toggleTask() {
        if taskLedger.activeTask == nil { startTask() } else { finishTask() }
    }

    private func startTask() {
        let alert = NSAlert()
        alert.messageText = l.text("startTaskTitle")
        alert.informativeText = l.text("startTaskInfo")
        alert.addButton(withTitle: l.text("startTask")); alert.addButton(withTitle: l.text("cancel"))
        let values = [("taskTitleField", true), ("taskProjectField", false), ("taskIssueField", false),
                      ("taskModelField", false), ("taskReasoningField", false)]
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 152))
        var fields: [NSTextField] = []
        for (index, value) in values.enumerated() {
            let field = NSTextField(string: "")
            field.placeholderString = l.text(value.0)
            field.setAccessibilityLabel(l.text(value.0))
            let y = CGFloat(values.count - index - 1) * 29 + 3
            field.frame = NSRect(x: 0, y: y, width: 360, height: 23)
            form.addSubview(field); fields.append(field)
        }
        alert.accessoryView = form
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = fields[0].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 500 else {
            showMessage(title: l.text("taskTitleRequired"), details: "")
            return
        }
        let snapshotID = appendBoundarySnapshot()
        do {
            try taskLedger.start(title: title, project: fields[1].stringValue, issue: fields[2].stringValue,
                                 model: fields[3].stringValue, reasoning: fields[4].stringValue,
                                 snapshotID: snapshotID, now: Date().timeIntervalSince1970)
            let saved = saveTaskData(); setupStatus(); writeStatus()
            if !saved { showMessage(title: l.text("taskSaveFailed"), details: "") }
        } catch {
            showMessage(title: l.text("taskTitleRequired"), details: "")
        }
    }

    private func finishTask() {
        guard taskLedger.activeTask != nil else {
            showMessage(title: l.text("taskNoActive"), details: "")
            return
        }
        let alert = NSAlert()
        alert.messageText = l.text("finishTaskTitle")
        alert.informativeText = l.text("finishTaskInfo")
        alert.addButton(withTitle: l.text("finishTask")); alert.addButton(withTitle: l.text("cancel"))
        let outcomes: [TaskOutcome] = [.accepted, .needsWork, .failed, .notRun, .interrupted, .abandoned]
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 91))
        let retries = NSTextField(string: "0")
        retries.placeholderString = l.text("taskRetriesField")
        retries.setAccessibilityLabel(l.text("taskRetriesField"))
        retries.frame = NSRect(x: 0, y: 64, width: 360, height: 23); form.addSubview(retries)
        let result = NSPopUpButton(frame: NSRect(x: 0, y: 34, width: 360, height: 24), pullsDown: false)
        result.addItems(withTitles: outcomes.map { outcomeTitle($0) })
        result.selectItem(at: outcomes.firstIndex(of: .notRun) ?? 0)
        result.setAccessibilityLabel(l.text("taskOutcomeField")); form.addSubview(result)
        let notes = NSTextField(string: "")
        notes.placeholderString = l.text("taskNotesField")
        notes.setAccessibilityLabel(l.text("taskNotesField"))
        notes.frame = NSRect(x: 0, y: 4, width: 360, height: 23); form.addSubview(notes)
        alert.accessoryView = form
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let retryCount = Int(retries.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              retryCount >= 0, retryCount <= 10_000 else {
            showMessage(title: l.text("taskRetriesField"), details: "0–10000")
            return
        }
        let snapshotID = appendBoundarySnapshot()
        do {
            try taskLedger.finish(retries: retryCount, outcome: outcomes[result.indexOfSelectedItem],
                                  validationNotes: notes.stringValue, snapshotID: snapshotID,
                                  now: Date().timeIntervalSince1970)
            let saved = saveTaskData(); setupStatus(); writeStatus()
            if !saved { showMessage(title: l.text("taskSaveFailed"), details: "") }
        } catch {
            showMessage(title: l.text("taskNoActive"), details: "")
        }
    }

    private func outcomeTitle(_ outcome: TaskOutcome) -> String {
        switch outcome {
        case .accepted: return l.text("outcomeAccepted")
        case .needsWork: return l.text("outcomeNeedsWork")
        case .failed: return l.text("outcomeFailed")
        case .notRun: return l.text("outcomeNotRun")
        case .interrupted: return l.text("outcomeInterrupted")
        case .abandoned: return l.text("outcomeAbandoned")
        }
    }

    private func taskDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return l.text("taskActiveLabel") }
        let whole = Int(seconds)
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \(whole % 3600 / 60)m"
    }

    private func periodSnapshotSummary(for record: TaskRecord) -> String {
        let start = accountObservations.snapshot(id: record.startSnapshotID)
        let end = accountObservations.snapshot(id: record.endSnapshotID)
        guard end != nil else { return "\(l.text("periodAccountChange")): \(l.text("observationUnavailable"))" }
        if let start, let end, let first = start.accountKey, let last = end.accountKey, first != last {
            return "\(l.text("periodAccountChange")): \(l.text("accountChanged"))"
        }
        let ids = Set((start?.quotaWindows ?? []).map(\.id)).intersection((end?.quotaWindows ?? []).map(\.id)).sorted()
        let values = ids.compactMap { id -> String? in
            let title = end?.quotaWindows.first(where: { $0.id == id })?.name ?? id
            switch observedQuotaChange(from: start, to: end, windowID: id) {
            case .change(let delta):
                let sign = delta > 0 ? "+" : ""
                return "\(title) \(sign)\(l.number(delta)) pp"
            case .reset: return "\(title): \(l.text("windowResetDuringTask"))"
            case .accountChanged: return l.text("accountChanged")
            case .unavailable: return nil
            }
        }
        let quota = values.isEmpty ? l.text("observationUnavailable") : values.joined(separator: ", ")
        var lines = ["\(l.text("periodAccountChange")): \(quota)"]
        let reached = ids.filter { id in
            guard case .change = observedQuotaChange(from: start, to: end, windowID: id),
                  let first = start?.quotaWindows.first(where: { $0.id == id })?.usedPercent,
                  let last = end?.quotaWindows.first(where: { $0.id == id })?.usedPercent else { return false }
            return first < 100 && last >= 100
        }
        if !reached.isEmpty { lines.append("\(l.text("windowReachedDuringTask")): \(reached.joined(separator: ", "))") }
        switch observedTokenCounterChange(from: start, to: end) {
        case .change(let delta):
            let sign = delta > 0 ? "+" : ""
            lines.append("\(l.text("periodAccountTokenChange")): \(sign)\(l.compact(delta))")
        case .reset: lines.append("\(l.text("periodAccountTokenChange")): \(l.text("windowResetDuringTask"))")
        case .accountChanged: lines.append("\(l.text("periodAccountTokenChange")): \(l.text("accountChanged"))")
        case .unavailable: break
        }
        return lines.joined(separator: "\n")
    }

    @objc private func showTaskHistory() {
        guard !taskLedger.records.isEmpty else {
            showMessage(title: l.text("taskHistory"), details: l.text("taskHistoryEmpty")); return
        }
        let formatter = DateFormatter()
        formatter.locale = l.locale; formatter.dateStyle = .short; formatter.timeStyle = .short
        let now = Date().timeIntervalSince1970
        let recent = taskLedger.records.suffix(25).reversed()
        let blocks = recent.map { record -> String in
            let project = [record.project, record.issue].compactMap { $0 }.joined(separator: " · ")
            let model = [record.model, record.reasoning].compactMap { $0 }.joined(separator: " · ")
            let result = record.outcome.map(outcomeTitle) ?? l.text("taskActiveLabel")
            let elapsed = record.durationSeconds ?? max(0, now - record.startedAt)
            var parts = ["\(record.title)", "\(formatter.string(from: Date(timeIntervalSince1970: record.startedAt))) · \(l.text("taskDuration")): \(taskDuration(elapsed))",
                         "\(l.text("taskOutcomeLabel")): \(result) · \(l.text("taskRetriesLabel")): \(record.retries.map(String.init) ?? "—")"]
            if !project.isEmpty { parts.append(project) }
            if !model.isEmpty { parts.append(model) }
            if record.endedAt != nil { parts.append(periodSnapshotSummary(for: record)) }
            if let notes = record.validationNotes { parts.append(notes) }
            parts.append(record.attributedSessionTokens.map { l.text("taskSessionTokens") + ": " + l.compact($0) } ?? l.text("taskSessionUsageUnavailable"))
            return parts.joined(separator: "\n")
        }
        showMessage(title: l.text("taskHistory"), details: blocks.joined(separator: "\n\n──────────\n\n"))
    }

    private func eventValue(_ value: Double?, sourceID: String) -> String {
        guard let value, value.isFinite else { return l.text("unavailable") }
        return sourceID == "codex.accountTokens" ? l.compact(value) : l.number(value, decimals: 1) + "%"
    }

    private func usageEventDescription(_ event: UsageLedgerEvent) -> String {
        let subject = event.windowName ?? event.windowID ?? sourceTitle(event.sourceID)
        let transition = "\(eventValue(event.previousValue, sourceID: event.sourceID)) → \(eventValue(event.currentValue, sourceID: event.sourceID))"
        switch event.kind {
        case .checkpoint:
            guard let observation = event.observation else { return l.text("eventCheckpoint") }
            var values = observation.quotaWindows.map { window in
                "\(window.name): \(eventValue(window.usedPercent, sourceID: "codex.quota"))"
            }
            if let previous = event.previousObservation,
               previous.accountKey == observation.accountKey,
               previous.quotaHealth == .fresh, observation.quotaHealth == .fresh {
                let oldWindows = Dictionary(previous.quotaWindows.map { ($0.id, $0) },
                                            uniquingKeysWith: { first, _ in first })
                let changes = observation.quotaWindows.compactMap { window -> String? in
                    guard let old = oldWindows[window.id],
                          let oldValue = old.usedPercent, let newValue = window.usedPercent,
                          old.windowDurationMins == window.windowDurationMins,
                          abs((old.resetsAt ?? 0) - (window.resetsAt ?? 0)) <= 60,
                          newValue >= oldValue else { return nil }
                    let delta = newValue - oldValue
                    let sign = delta > 0 ? "+" : ""
                    return "\(window.name) \(sign)\(l.number(delta)) pp"
                }
                if !changes.isEmpty {
                    values.append("\(l.text("eventSincePriorCheckpoint")): \(changes.joined(separator: ", "))")
                }
                if previous.tokenHealth == .fresh, observation.tokenHealth == .fresh,
                   let oldTotal = previous.accountTokenTotal, let newTotal = observation.accountTokenTotal,
                   newTotal >= oldTotal {
                    let delta = newTotal - oldTotal
                    let sign = delta > 0 ? "+" : ""
                    values.append("\(l.text("eventAccountTokens")): \(sign)\(l.compact(delta))")
                }
            }
            if let tokens = observation.accountTokenTotal {
                values.append("\(l.text("eventAccountTokenTotal")): \(l.compact(tokens))")
            }
            return l.text("eventCheckpoint") + " · " + (values.isEmpty ? l.text("unavailable") : values.joined(separator: ", "))
        case .dataGap:
            return "\(l.text("eventDataGap")) · \(taskDuration(event.gapSeconds))"
        case .accountSwitch:
            return l.text("eventAccountSwitch")
        case .windowReset:
            return "\(l.text("eventWindowReset")) · \(subject) · \(transition)"
        case .sourceCorrection:
            return "\(l.text("eventSourceCorrection")) · \(subject) · \(transition)"
        case .windowUnavailable:
            return "\(l.text("eventWindowUnavailable")) · \(subject)"
        case .windowRestored:
            return "\(l.text("eventWindowRestored")) · \(subject) · \(eventValue(event.currentValue, sourceID: event.sourceID))"
        case .sourceFailure:
            let code = event.detailCode.map { l.text($0) } ?? l.text("sourceError")
            return "\(l.text("eventSourceFailure")) · \(sourceTitle(event.sourceID)) · \(code)"
        case .sourceRecovered:
            return "\(l.text("eventSourceRecovered")) · \(sourceTitle(event.sourceID))"
        }
    }

    @objc private func showUsageEventHistory() {
        guard !usageEventLedger.recentEvents.isEmpty else {
            showMessage(title: l.text("usageEventHistory"), details: l.text("usageEventHistoryEmpty")); return
        }
        let formatter = DateFormatter()
        formatter.locale = l.locale; formatter.dateStyle = .short; formatter.timeStyle = .short
        let blocks = usageEventLedger.recentEvents.suffix(30).reversed().map { event in
            "\(formatter.string(from: Date(timeIntervalSince1970: event.timestamp))) · \(usageEventDescription(event))"
        }
        showMessage(title: l.text("usageEventHistory"), details: blocks.joined(separator: "\n\n──────────\n\n"))
    }

    @objc private func exportUsageEvents() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "codex-usage-events.jsonl"
        panel.message = l.text("usageEventExportPrompt")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        persistUsageEventChanges([], now: Date().timeIntervalSince1970)
        let source = support.appendingPathComponent("usage-events.jsonl")
        let sources = usageEventFiles()
        var temporaryURL: URL?
        defer {
            if let temporaryURL, FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        do {
            if !FileManager.default.fileExists(atPath: source.path) {
                _ = FileManager.default.createFile(atPath: source.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            }
            if source.standardizedFileURL != url.standardizedFileURL {
                let temporary = url.deletingLastPathComponent()
                    .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
                temporaryURL = temporary
                guard FileManager.default.createFile(atPath: temporary.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let output = try FileHandle(forWritingTo: temporary)
                defer { try? output.close() }
                for file in sources {
                    var data = try Data(contentsOf: file, options: .mappedIfSafe)
                    if let last = data.last, last != 0x0A { data.append(0x0A) }
                    try output.write(contentsOf: data)
                }
                try output.synchronize()
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: url)
                }
            }
            showMessage(title: l.text("usageEventExported"), details: url.lastPathComponent)
        } catch {
            showMessage(title: l.text("usageEventExportFailed"), details: "")
        }
    }

    @objc private func exportTaskLedger() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "codex-task-ledger.json"
        panel.message = l.text("taskExportPrompt")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let export = TaskLedgerExport(exportedAt: Date().timeIntervalSince1970,
                                      taskLedger: taskLedger, accountObservations: accountObservations)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(export).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            showMessage(title: l.text("taskExported"), details: url.lastPathComponent)
        } catch {
            showMessage(title: l.text("taskExportFailed"), details: "")
        }
    }

    @objc private func showSourceDiagnostics() {
        showMessage(title: l.text("sourceDiagnostics"), details: diagnosticsText())
    }

    private func showMessage(title: String, details: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = details
        alert.addButton(withTitle: l.text("ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func writeStatus() {
        let now = Date().timeIntervalSince1970
        var data: [String: Any] = ["schemaVersion": 4, "stale": current.map { isStale($0, now: now) } ?? stale, "collapsed": collapsed, "pinned": pinned,
            "visible": panel?.isVisible ?? false, "pid": ProcessInfo.processInfo.processIdentifier,
            "windows": items.map { ["id": $0.id, "title": title(for: $0)] },
            "frame": NSStringFromRect(panel?.frame ?? .zero)]
        data["displayedWindows"] = ([current].compactMap { $0 } + extraItems).map(\.id)
        data["energySaver"] = settings.options.energySaver
        data["enabledBridges"] = settings.options.bridges
        data["quotaAlerts"] = settings.quotaAlertsEnabled
        data["autoContinue"] = settings.autoContinueEnabled
        data["autoConnect"] = settings.autoConnectEnabled
        data["openAtLogin"] = LoginItem.isEnabled
        data["autoConnectResults"] = autoConnectResults
        data["claudePlanError"] = claudePlanError
        let decision = AgentRouter.decide(mode: settings.routerMode ?? .auto, items: items, now: now)
        var router: [String: Any] = ["mode": (settings.routerMode ?? .auto).rawValue, "reason": decision.reason,
                                     "minimumHeadroom": AgentRouter.minimumHeadroom,
                                     "agents": decision.agents.map { a -> [String: Any] in
                                         var entry: [String: Any] = ["provider": a.provider, "headroom": a.headroom]
                                         entry["limitingWindow"] = a.limitingWindow; entry["resetsAt"] = a.resetsAt
                                         return entry }]
        router["agent"] = decision.agent ?? NSNull()
        router["byTask"] = Dictionary(uniqueKeysWithValues: TaskKind.allCases.map { kind -> (String, Any) in
            let pick = AgentRouter.assign(kind, rules: settings.taskRouting, mode: settings.routerMode ?? .auto, items: items, now: now)
            return (kind.rawValue, ["agent": pick.agent ?? NSNull(), "reason": pick.reason, "rule": settings.taskRouting[kind]?.rawValue ?? "auto"] as [String: Any])
        })
        data["router"] = router
        data["suggestedAgent"] = decision.agent
        data["autoContinueBlocked"] = autoContinuePlanner.isBlocked
        if let last = lastAutoContinue {
            var entry: [String: Any] = ["at": last.at, "result": last.result]
            entry["session"] = last.session
            data["lastAutoContinue"] = entry
        }
        if settings.agentLogsEnabled, let scanned = agentLastScanAt {
            let since = now - settings.lookback
            let summary = agentLedger.summary(since: since, now: now)
            func encode(_ b: TokenBreakdown) -> [String: Double] {
                ["input": b.input, "cacheRead": b.cacheRead, "cacheWrite": b.cacheWrite, "output": b.output, "reasoning": b.reasoning, "total": b.total]
            }
            data["deepSeekBalances"] = deepSeekBalances.map { ["currency": $0.currency, "total": $0.total] }
            data["agentTokens"] = ["windowSeconds": settings.lookback, "scannedAt": scanned,
                                   "total": encode(agentLedger.total(since: since, now: now)),
                                   "providers": summary.mapValues(encode)] as [String: Any]
        }
        data["selectedWindow"] = current?.id
        data["usedPercent"] = current?.window.validUsedPercent
        data["resetsAt"] = current?.window.resetsAt
        data["lastUpdate"] = lastUpdate?.timeIntervalSince1970
        let sourceError = current.flatMap { providerFor($0) } == nil ? errorMessage : nil
        data["errorCode"] = sourceError
        data["error"] = sourceError.map { l.text($0) }
        data["codexErrorCode"] = errorMessage
        data["language"] = settings.language.rawValue
        data["observationSeconds"] = settings.lookback
        data["rateUnit"] = settings.rateUnit.rawValue
        data["planType"] = current?.planType
        if let current, let provider = providerFor(current) { data["lastUpdate"] = bridgeSnapshots[provider]?.updatedAt }
        let state = client.diagnostics
        data["lastAttemptAt"] = state.lastAttemptAt
        data["lastQuotaSuccessAt"] = state.lastQuotaSuccessAt
        data["lastTokenAttemptAt"] = state.lastTokenAttemptAt
        data["lastTokenSuccessAt"] = state.lastTokenSuccessAt
        data["tokenErrorCode"] = state.lastTokenErrorCode
        data["nextAttemptAt"] = state.nextAttemptAt
        data["consecutiveFailures"] = state.consecutiveFailures
        let sourceData = sourceDiagnostics(now: now).reduce(into: [String: [String: Any]]()) { result, source in
            var entry: [String: Any] = ["health": source.health.rawValue, "enabled": source.enabled,
                                        "staleAfterSeconds": source.staleAfterSeconds,
                                        "consecutiveFailures": source.consecutiveFailures]
            if let value = source.lastAttemptAt { entry["lastAttemptAt"] = value }
            if let value = source.lastSuccessAt { entry["lastSuccessAt"] = value }
            if let value = source.ageSeconds { entry["ageSeconds"] = value }
            if let value = source.lastErrorCode { entry["lastErrorCode"] = value }
            if let value = source.nextAttemptAt { entry["nextAttemptAt"] = value }
            result[source.id] = entry
        }
        data["sources"] = sourceData
        data["taskRecordCount"] = taskLedger.records.count
        data["usageEventCount"] = usageEventLedger.state.eventCount
        if let task = taskLedger.activeTask {
            var active: [String: Any] = ["id": task.id, "title": task.title, "startedAt": task.startedAt]
            active["project"] = task.project; active["issue"] = task.issue
            active["model"] = task.model; active["reasoning"] = task.reasoning
            data["activeTask"] = active
        } else { data["activeTask"] = NSNull() }
        let tokenIsStale = !tokenAvailable || state.lastTokenSuccessAt.map { now - $0 > client.pollInterval + 30 } ?? true
        data["tokenRatePerHour"] = tokenIsStale ? nil : tokenHistory.rate(now: Date().timeIntervalSince1970, lookback: settings.lookback)?.perHour
        data["tokenAvailable"] = tokenAvailable
        data["ratePerHour"] = current.flatMap { (isStale($0, now: now) || ($0.window.resetsAt.map { $0 <= now } ?? false)) ? nil : cachedRates[$0.id]?.perHour }
        data["planRatePerHour"] = data["ratePerHour"]
        let forecast = forecastQuota(used: current?.window.validUsedPercent, perHour: data["ratePerHour"] as? Double, resetsAt: current?.window.resetsAt, now: now)
        data["forecast"] = forecast.map { value -> [String: Any] in
            var entry: [String: Any] = ["outlook": value.outlook.rawValue, "projectedUsedAtReset": value.projectedUsedAtReset]
            if let exhaustsAt = value.exhaustsAt { entry["exhaustsAt"] = exhaustsAt }
            return entry
        } ?? NSNull()
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: support.appendingPathComponent("status.json"), options: .atomic)
        }
    }
    @objc private func selectWindow() {
        let menu = NSMenu()
        for item in items {
            let entry = NSMenuItem(title: title(for: item), action: #selector(chosen(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = item.id; entry.state = item.id == current?.id ? .on : .off; menu.addItem(entry)
        }
        if items.isEmpty { let entry = NSMenuItem(title: l.text("noQuota"), action: nil, keyEquivalent: ""); entry.isEnabled = false; menu.addItem(entry) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: titleButton)
    }
    @objc private func chosen(_ sender: NSMenuItem) {
        selectedID = sender.representedObject as? String
        defaults.set(selectedID, forKey: "selectedWindow"); resize(); screensChanged(); render(); writeStatus()
    }
    @objc private func toggleCollapsed() {
        collapsed.toggle(); defaults.set(collapsed, forKey: "collapsed"); resize(); screensChanged(); render(); savePosition(); writeStatus()
    }
    @objc private func togglePinned(_ sender: NSMenuItem) {
        pinned.toggle(); defaults.set(pinned, forKey: "pinned"); panel.level = pinned ? .floating : .normal
        sender.state = pinned ? .on : .off; writeStatus()
    }
    @objc private func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil); tick?.invalidate(); writeStatus() } else { showPanel() }
    }
    @objc private func showPanel() { screensChanged(); panel.orderFrontRegardless(); startUITimer(); render(); writeStatus() }
    @objc private func refresh() { client.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func willSleep() { sleeping = true; tick?.invalidate(); client.suspend(); errorMessage = "asleep"; writeStatus() }
    @objc private func didWake() { sleeping = false; client.resume(); startUITimer(); reloadBridges(); render() }
    @objc private func screensChanged() {
        guard let panel, !NSScreen.screens.isEmpty else { return }
        panel.setFrameOrigin(visibleOrigin(for: panel.frame, screens: NSScreen.screens.map(\.visibleFrame)))
    }
    private func savePosition() {
        defaults.set(panel.frame.minX, forKey: "positionX"); defaults.set(panel.frame.minY, forKey: "positionY")
    }
    func windowDidMove(_ notification: Notification) { if !adjustingFrame { savePosition(); writeStatus() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        tick?.invalidate(); bridgeTick?.invalidate()
        persistUsageEventChanges([], now: Date().timeIntervalSince1970)
        client.stop(); flock(lockFD, LOCK_UN); close(lockFD)
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
