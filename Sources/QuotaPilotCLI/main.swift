import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import UsageCore
import UsageTransport

// quotapilot — cross-platform command-line companion to the QuotaPilot menu bar app.
// Reads Codex quota (Codex app server), Claude plan usage (Claude Code login), local agent token logs,
// and answers "which agent should take this task" for skills and scripts.

let version = "0.9.2"
let arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
/// Hours as a short label: `24h`, `7d`, `30m`, `1.5h`.
func hoursLabel(_ hours: Double) -> String {
    if hours >= 24, hours.truncatingRemainder(dividingBy: 24) == 0 { return "\(Int(hours / 24))d" }
    if hours < 1 { return "\(Int((hours * 60).rounded()))m" }
    return hours == hours.rounded() ? "\(Int(hours))h" : l.number(hours, decimals: 1) + "h"
}
func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(code)
}

// MARK: Configuration (shared with the macOS app when present)

let stateDirectory = Portable.stateDirectory()
let configURL = stateDirectory.appendingPathComponent("cli-config.json")

func loadSettings() -> WidgetSettings {
    #if os(macOS)
    if let data = UserDefaults(suiteName: "io.github.dwagwd.quotapilot")?.data(forKey: "settings"),
       let settings = try? JSONDecoder().decode(WidgetSettings.self, from: data) { return settings }
    #endif
    if let data = try? Data(contentsOf: configURL), let settings = try? JSONDecoder().decode(WidgetSettings.self, from: data) { return settings }
    var settings = WidgetSettings()
    settings.claudePlanEnabled = false // Standalone CLI must opt in before reading saved credentials.
    return settings
}

func saveCLISettings(_ settings: WidgetSettings) {
    try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(settings) else { fail("Could not encode settings") }
    #if os(macOS)
    // loadSettings prefers the app's settings, so changes must land there too or they would be ignored.
    if let defaults = UserDefaults(suiteName: "io.github.dwagwd.quotapilot"), defaults.data(forKey: "settings") != nil {
        defaults.set(data, forKey: "settings")
        defaults.synchronize()
    }
    #endif
    do { try data.write(to: configURL, options: .atomic) } catch { fail("Could not write \(configURL.path): \(error.localizedDescription)") }
}

// MARK: Data sources

/// Codex plan quota through the Codex app server (same path as the menu bar app).
/// A Codex app-server client with its latest result or failure. One-shot commands make one per fetch;
/// `watch` keeps one for the whole run, so the app server starts once instead of on every refresh.
final class CodexSession {
    let client: UsageClient
    var windows: [WindowItem]?
    var failure: String?
    init(keepAlive: Bool) {
        client = UsageClient(requestTimeout: 20)
        // The session is refreshed explicitly each cycle; the client's own polling would only add requests.
        if keepAlive { client.pollInterval = 86400 }
        client.onResult = { [weak self] response, _ in self?.windows = response.windows() }
        client.onFailure = { [weak self] code in self?.failure = code }
        if ProcessInfo.processInfo.environment["QUOTAPILOT_DEBUG"] != nil {
            client.onDiagnostics = { [weak self] d in FileHandle.standardError.write(Data("diag connected=\(d.connected) inflight=\(d.requestInFlight) fail=\(d.lastFailureCode ?? "-") exe=\(self?.client.executable ?? "-")\n".utf8)) }
        }
    }
}
var watchSession: CodexSession?
#if !os(Windows)
var watchSignalSources: [DispatchSourceSignal] = []
#endif

/// Error text for a one-shot command. The app's strings for these codes end with "retrying" or "reconnecting",
/// which is true for the menu bar app but not for a command that exits right after printing.
func cliText(_ code: String) -> String {
    let short: [String: [String: String]] = [
        "timeout": ["en": "Codex did not answer in time.", "zh-Hant": "Codex 未在時限內回應。", "zh-Hans": "Codex 未在时限内响应。"],
        "disconnected": ["en": "Codex disconnected.", "zh-Hant": "Codex 連線中斷。", "zh-Hans": "Codex 连接中断。"],
        "serviceStopped": ["en": "Codex service stopped.", "zh-Hant": "Codex 服務已停止。", "zh-Hans": "Codex 服务已停止。"]
    ]
    if let table = short[code] { return table[l.code] ?? table["en"] ?? code }
    return l.text(code)
}

func fetchCodexWindows(timeout: Double = 30) -> (windows: [WindowItem], error: String?) {
    let session = watchSession ?? CodexSession(keepAlive: false)
    session.windows = nil; session.failure = nil
    session.client.refresh()
    let deadline = Date().addingTimeInterval(timeout)
    var lastKick = Date()
    while session.windows == nil && Date() < deadline {
        if session.failure == "clientMissing" { break }
        // A long-lived session may have returned the previous cycle while its token read was still in flight; if
        // that read never completed, the client is idle and ignores nothing now, so ask again every few seconds.
        if watchSession != nil, Date().timeIntervalSince(lastKick) >= 2 {
            let d = session.client.diagnostics
            if !d.requestInFlight && !d.connected { session.client.refresh(); lastKick = Date() }
        }
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    if watchSession == nil { session.client.stop() }
    if let windows = session.windows { return (windows, nil) }
    return ([], session.failure ?? "timeout")
}

func fetchClaudeWindows() -> (windows: [WindowItem], error: String?) {
    // Fresh quota from Claude Code's status line needs no login at all.
    if let bridge = ClaudeBridgeSource.freshSnapshot() { return (bridge.limits.windows(), nil) }
    let login: ClaudeLogin
    switch ClaudeKeychain.shared.login() {
    case .login(let found): login = found
    case .missing: return ([], "claudeLoginMissing")
    case .expired: return ([], "claudeLoginExpired")
    case .needsAccess: return ([], "claudeLoginNeedsAccess")
    }
    var request = URLRequest(url: ClaudePlanUsage.endpoint, timeoutInterval: 20)
    request.setValue("Bearer " + login.token, forHTTPHeaderField: "Authorization")
    request.setValue(ClaudePlanUsage.betaHeader, forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let done = DispatchSemaphore(value: 0)
    var body: Data?, status = 0
    // Older versions cached this request, token included, in ~/Library/Caches/QuotaPilot/Cache.db.
    SecretSession.purgeSharedCache()
    SecretSession.shared.dataTask(with: request) { data, response, _ in
        body = data; status = (response as? HTTPURLResponse)?.statusCode ?? 0; done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 25)
    guard (200..<300).contains(status), let body,
          let snapshot = ClaudePlanUsage.snapshot(from: body, plan: login.plan, account: ClaudePlanUsage.localAccountID(home: FileManager.default.homeDirectoryForCurrentUser), now: Date().timeIntervalSince1970) else {
        if status == 401 { ClaudeKeychain.shared.reject() }
        return ([], status == 401 ? "claudeLoginExpired" : "claudePlanUnavailable")
    }
    return (snapshot.limits.windows(), nil)
}

var modelTracker = AgentModelTracker()
var speedSamples: [OutputSpeedSample] = []

/// Per-agent output speed: output tokens (with reasoning) over model-call time. A lower bound on decode tok/s.
func speedText() -> [String] {
    Dictionary(grouping: speedSamples, by: \.provider).sorted { $0.key < $1.key }.compactMap { provider, samples in
        guard let s = OutputSpeedSummary(samples) else { return nil }
        return "\(providerName(provider)) ≈\(l.number(s.tokensPerSecond, decimals: 0)) tok/s (median \(l.number(s.medianTokensPerSecond, decimals: 0)), \(s.calls) calls)"
    }
}

/// Log reading state kept across refreshes. A one-shot command reads once; `watch` keeps the scanner and ledger, so
/// every refresh after the first reads only the bytes appended since the last one.
final class TokenState {
    let scanner = AgentLogScanner(sources: AgentLogScanner.defaultSources(home: FileManager.default.homeDirectoryForCurrentUser))
    var ledger = AgentTokenLedger()
    var samples: [OutputSpeedSample] = []
}
var tokenState = TokenState()

func tokenSummary(hours: Double) -> [String: TokenBreakdown] {
    let settings = loadSettings()
    let now = Date().timeIntervalSince1970, since = now - hours * 3600
    // Local model usage (Ollama, LM Studio, llama.cpp, oMLX) comes from the event file the meter writes; see docs/local-llm.md.
    if settings.localModels.isEnabled {
        for event in LocalLLMLog(url: LocalLLMLog.defaultURL(stateDirectory: stateDirectory)).events(since: since) { tokenState.ledger.add(event.tokenEvent) }
    }
    guard settings.agentLogsEnabled else {
        modelTracker = AgentModelTracker(); speedSamples = []
        let keep = tokenState.ledger
        tokenState = TokenState(); tokenState.ledger = keep
        return tokenState.ledger.summary(since: since, now: now)
    }
    let localRule = settings.localLLM
    for event in tokenState.scanner.scan(windowStart: since, now: now) where !LocalLLMIntegration.skipsAgentEvent(event, settings: localRule) { tokenState.ledger.add(event) }
    tokenState.ledger.prune(now: now)
    for model in tokenState.scanner.lastModelEvents { modelTracker.observe(model) }
    tokenState.samples = (tokenState.samples + tokenState.scanner.lastSpeedSamples).filter { $0.timestamp >= since }
    speedSamples = tokenState.samples
    return tokenState.ledger.summary(since: since, now: now)
}

/// Cost, cache and share statistics for the same window as `tokenSummary` (call that first).
func usageReport(hours: Double) -> UsageReport {
    let now = Date().timeIntervalSince1970
    return UsageReport(tokenState.ledger.statsInput(since: now - hours * 3600, now: now))
}

func reportJSON(_ report: UsageReport) -> [String: Any] {
    func line(_ l: UsageReport.Line) -> [String: Any] {
        ["id": l.id, "provider": l.provider, "model": l.model ?? NSNull(), "tokens": breakdownJSON(l.usage), "calls": l.calls,
         "priceStatus": l.status.rawValue, "costUSD": l.costUSD ?? NSNull(), "share": l.share]
    }
    return ["equivalentApiCostUSD": report.costUSD, "unpricedTokens": report.unpricedTokens, "localTokens": report.localTokens,
            "calls": report.calls, "activeMinutes": report.activeMinutes, "activeMinutesIsApproximate": true,
            "cacheHitRate": report.cacheHitRate ?? NSNull(), "cacheSavingsUSD": report.cacheSavingsUSD,
            "categoryShares": Dictionary(uniqueKeysWithValues: report.categories.map { ($0.kind.rawValue, ["tokens": $0.tokens, "share": $0.share]) }),
            "byProvider": report.providers.map(line), "byModel": report.models.map(line),
            "note": "List-price equivalent for models with a known price; a subscription does not pay this."]
}

func reportText(_ report: UsageReport) -> [String] {
    guard report.total.total > 0 else { return [] }
    var lines = ["≈ \(l.usd(report.costUSD)) equivalent API price (list price; subscription users don't pay this)"
                 + (report.hasUnpriced ? " + \(l.compact(report.unpricedTokens)) tokens not priced" : "")]
    lines.append("\(l.compact(Double(report.calls))) calls · active ≈ \(l.activeTime(minutes: report.activeMinutes)) (approx.: 5-minute slots with any call)")
    if let rate = report.cacheHitRate {
        lines.append("Cache hit rate \(l.percent(rate))" + (report.cacheSavingsUSD > 0 ? " · saves ≈ \(l.usd(report.cacheSavingsUSD)) versus no cache" : ""))
    }
    lines.append("Where the tokens went: " + report.categories.map { "\(l.categoryName($0.kind)) \(l.percent($0.share))" }.joined(separator: " · "))
    func text(_ line: UsageReport.Line, _ name: String) -> String {
        "  " + name.padding(toLength: 34, withPad: " ", startingAt: 0) + l.percent(line.share).padding(toLength: 6, withPad: " ", startingAt: 0)
            + l.costText(line).padding(toLength: 11, withPad: " ", startingAt: 0) + "\(line.calls) calls"
    }
    lines.append("By agent")
    for line in report.providers { lines.append(text(line, (line.provider == "local" ? "Local" : providerName(line.provider)) + (line.hasUnpriced ? " +" : ""))) }
    lines.append("By model")
    for line in report.models { lines.append(text(line, l.modelName(line) + (line.provider == "local" ? "" : " (" + providerName(line.provider) + ")"))) }
    return lines
}

// MARK: Formatting

let l = L10n(.english)
func providerName(_ id: String) -> String {
    ["codex": "Codex", "claude": "Claude", "gemini": "Gemini", "grok": "Grok", "antigravity": "Antigravity", "cursor": "Cursor",
     "deepseek": "DeepSeek", "kimi": "Kimi", "glm": "GLM", "qwen": "Qwen"][id] ?? id
}
func shortWindow(_ minutes: Int?) -> String {
    guard let m = minutes, m > 0 else { return "?" }
    if m == 10080 { return "wk" }
    if m % 1440 == 0 { return "\(m / 1440)d" }
    if m % 60 == 0 { return "\(m / 60)h" }
    return "\(m)m"
}
func shortCountdown(_ reset: Double?, now: Double) -> String {
    guard let reset, reset > now else { return "" }
    let s = Int(reset - now)
    if s >= 86400 { return "↻\(s / 86400)d\(s % 86400 / 3600)h" }
    if s >= 3600 { return "↻\(s / 3600)h\(s % 3600 / 60)m" }
    return "↻\(max(1, s / 60))m"
}
func breakdownText(_ b: TokenBreakdown) -> String {
    "input \(l.compact(b.input)) · cache read \(l.compact(b.cacheRead)) · cache write \(l.compact(b.cacheWrite)) · output \(l.compact(b.output))"
        + (b.reasoning > 0 ? " (reasoning \(l.compact(b.reasoning)))" : "")
}
func breakdownJSON(_ b: TokenBreakdown) -> [String: Double] {
    ["input": b.input, "cacheRead": b.cacheRead, "cacheWrite": b.cacheWrite, "output": b.output, "reasoning": b.reasoning, "total": b.total]
}
func printJSON(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { fail("Could not encode JSON") }
    print(String(decoding: data, as: UTF8.self))
}

struct Snapshot {
    let windows: [WindowItem]
    let errors: [String: String]
    let tokens: [String: TokenBreakdown]
    let tokenHours: Double
    let settings: WidgetSettings
    let now: Double
}

func collect(tokenHours: Double, includeTokens: Bool = true) -> Snapshot {
    let settings = loadSettings()
    var errors: [String: String] = [:]
    let codex = fetchCodexWindows()
    if let error = codex.error { errors["codex"] = error }
    let claude: (windows: [WindowItem], error: String?) = (settings.claudePlanEnabled && AgentDetectionCLI.claudeInstalled) ? fetchClaudeWindows() : ([], nil)
    if let error = claude.error { errors["claude"] = error }
    return Snapshot(windows: codex.windows + claude.windows, errors: errors,
                    tokens: includeTokens ? tokenSummary(hours: tokenHours) : [:], tokenHours: tokenHours,
                    settings: settings, now: Date().timeIntervalSince1970)
}

enum AgentDetectionCLI {
    static var claudeInstalled: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
    }
}

func groups(_ windows: [WindowItem], settings: WidgetSettings, now: Double) -> [[WindowItem]] {
    var order: [String] = [], map: [String: [WindowItem]] = [:]
    for item in windows {
        let key = String(item.id.split(separator: ":").first ?? "")
        if map[key] == nil { order.append(key) }
        map[key, default: []].append(item)
    }
    let sorted = order.compactMap { map[$0]?.sorted { ($0.window.windowDurationMins ?? .max) < ($1.window.windowDurationMins ?? .max) } }
    return sortQuotaGroups(sorted, sort: settings.quotaSort ?? .detected, pinned: settings.pinnedProviders ?? [], now: now)
}

func routerObject(_ snapshot: Snapshot) -> [String: Any] {
    let mode = snapshot.settings.routerMode ?? .auto
    let decision = AgentRouter.decide(mode: mode, items: snapshot.windows, now: snapshot.now)
    var byTask: [String: Any] = [:]
    for kind in TaskKind.allCases {
        let pick = AgentRouter.assign(kind, rules: snapshot.settings.taskRouting, mode: mode, items: snapshot.windows, now: snapshot.now)
        byTask[kind.rawValue] = ["agent": pick.agent ?? NSNull(), "reason": pick.reason,
                                 "rule": snapshot.settings.taskRouting[kind]?.rawValue ?? "auto"] as [String: Any]
    }
    return ["mode": mode.rawValue, "agent": decision.agent ?? NSNull(), "reason": decision.reason, "byTask": byTask,
            "minimumHeadroom": AgentRouter.minimumHeadroom,
            "agents": decision.agents.map { ["provider": $0.provider, "headroom": $0.headroom, "limitingWindow": $0.limitingWindow ?? NSNull(), "resetsAt": $0.resetsAt ?? NSNull()] as [String: Any] }]
}

func statusObject(_ snapshot: Snapshot) -> [String: Any] {
    let total = snapshot.tokens.values.reduce(into: TokenBreakdown()) { $0.add($1) }
    return [
        "version": version, "generatedAt": snapshot.now, "errors": snapshot.errors,
        "windows": snapshot.windows.map { item -> [String: Any] in
            ["id": item.id, "name": item.name, "planType": item.planType ?? NSNull(), "planName": PlanCatalog.displayName(provider: item.id.split(separator: ":").first.map(String.init), raw: item.planType) ?? NSNull(), "usedPercent": item.window.validUsedPercent ?? NSNull(),
             "windowDurationMins": item.window.windowDurationMins ?? NSNull(), "resetsAt": item.window.resetsAt ?? NSNull(), "limitReached": item.limitReached]
        },
        "tokens": ["hours": snapshot.tokenHours, "total": breakdownJSON(total), "providers": snapshot.tokens.mapValues(breakdownJSON)] as [String: Any],
        "router": routerObject(snapshot),
        "models": Dictionary(uniqueKeysWithValues: modelTracker.current.map { ($0.key, ["model": $0.value.model, "effort": $0.value.effort ?? NSNull(), "at": $0.value.at] as [String: Any]) }),
        "reroutes": modelTracker.reroutes.map { ["provider": $0.provider, "at": $0.timestamp, "from": $0.fromModel ?? NSNull(), "to": $0.model, "reason": $0.reason ?? NSNull()] as [String: Any] }
    ]
}

func renderText(_ snapshot: Snapshot) -> String {
    var lines: [String] = []
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
    lines.append("QuotaPilot · " + formatter.string(from: Date(timeIntervalSince1970: snapshot.now)))
    for group in groups(snapshot.windows, settings: snapshot.settings, now: snapshot.now) {
        let name = (group.first?.name ?? "").padding(toLength: 8, withPad: " ", startingAt: 0)
        lines.append(name + group.map { item in
            shortWindow(item.window.windowDurationMins) + " " + (item.window.validUsedPercent.map { l.number($0, decimals: 0) + "%" } ?? "—")
                + " " + shortCountdown(item.window.resetsAt, now: snapshot.now)
        }.joined(separator: "  "))
    }
    for (agent, error) in snapshot.errors.sorted(by: { $0.key < $1.key }) { lines.append(providerName(agent) + ": " + cliText(error)) }
    if !snapshot.tokens.isEmpty {
        let total = snapshot.tokens.values.reduce(into: TokenBreakdown()) { $0.add($1) }
        lines.append("Tokens (\(hoursLabel(snapshot.tokenHours))): " + l.compact(total.total) + " · ≈" + l.compact(total.total / snapshot.tokenHours) + "/h · "
                     + snapshot.tokens.sorted { $0.value.total > $1.value.total }.map { providerName($0.key) + " " + l.compact($0.value.total) }.joined(separator: " · "))
        lines.append("  " + breakdownText(total))
    }
    let speeds = speedText()
    if !speeds.isEmpty { lines.append("Output speed: " + speeds.joined(separator: " · ") + "  (output ÷ call time, decode lower bound)") }
    if !modelTracker.current.isEmpty {
        lines.append("Models: " + modelTracker.current.sorted { $0.key < $1.key }.map { provider, current in
            providerName(provider) + " " + current.model + (current.effort.map { " (\($0))" } ?? "")
        }.joined(separator: " · "))
    }
    for reroute in modelTracker.reroutes.suffix(3) {
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"
        lines.append("⚠ Rerouted \(formatter.string(from: Date(timeIntervalSince1970: reroute.timestamp))): \(reroute.fromModel ?? "?") → \(reroute.model)" + (reroute.reason.map { " (\($0))" } ?? ""))
    }
    let mode = snapshot.settings.routerMode ?? .auto
    lines.append("Route (\(mode.rawValue)): " + TaskKind.allCases.map { kind in
        let pick = AgentRouter.assign(kind, rules: snapshot.settings.taskRouting, mode: mode, items: snapshot.windows, now: snapshot.now)
        return kind.rawValue + "→" + (pick.agent ?? "none") + (pick.reason == "ruleLowQuota" ? "*" : "")
    }.joined(separator: "  ") + "   (* quota fallback)")
    return lines.joined(separator: "\n")
}

// MARK: Share (opt-in)

/// Kinds to share: `--only speed,quota` for this run, otherwise the app's "What to share" setting.
func shareKinds() -> Set<ShareCategory> {
    if let i = arguments.firstIndex(of: "--only"), i + 1 < arguments.count {
        let kinds = arguments[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let known = Set(kinds.compactMap(ShareCategory.init(rawValue:)))
        guard known.count == kinds.count, !known.isEmpty else {
            fail("--only takes a comma-separated list of: " + ShareCategory.allCases.map(\.rawValue).joined(separator: ", "), code: 2)
        }
        return known
    }
    return loadSettings().sharedCategories
}

/// Collects the anonymous numbers for `share`. Reads the same sources as `status`; sends nothing.
func shareReports(hours: Double) -> (reports: [[String: Any]], errors: [String: String]) {
    let settings = loadSettings()
    let now = Date().timeIntervalSince1970
    var errors: [String: String] = [:]
    let codex = fetchCodexWindows()
    if let error = codex.error { errors["codex"] = error }
    let claude: (windows: [WindowItem], error: String?) = (settings.claudePlanEnabled && AgentDetectionCLI.claudeInstalled) ? fetchClaudeWindows() : ([], nil)
    if let error = claude.error { errors["claude"] = error }
    let windows = (codex.windows + claude.windows).filter { ContributionReport.sharedProvider(windowID: $0.id) != nil }
    let starts = windows.compactMap { item -> Double? in
        guard let reset = item.window.resetsAt, let mins = item.window.windowDurationMins else { return nil }
        return reset - Double(mins) * 60
    }
    let earliest = min(now - hours * 3600, starts.min() ?? now)
    let scanner = AgentLogScanner(sources: AgentLogScanner.defaultSources(home: FileManager.default.homeDirectoryForCurrentUser))
    let events = settings.agentLogsEnabled ? scanner.scan(windowStart: max(earliest, now - 8 * 86400), now: now) : []
    for model in scanner.lastModelEvents { modelTracker.observe(model) }
    let speed = scanner.lastSpeedSamples.filter { $0.timestamp >= now - hours * 3600 }
    // First-seen times of limits the menu bar app recorded (the CLI cannot see them itself).
    let seen = LimitSightings.load(from: LimitSightings.fileURL(in: stateDirectory))
    let uses = ContributionReport.windowUses(items: windows, tokensSince: { provider, start in
        events.filter { $0.provider == provider && $0.timestamp >= start }.reduce(into: TokenBreakdown()) { $0.add($1.usage) }
    }, model: { modelTracker.current[$0]?.model }, limitSince: { id, reset in
        reset.flatMap { LimitSightings.lookup(seen, windowID: id, resetsAt: $0) }
    })
    let kinds = shareKinds()
    // Local runs (opt-in): the speed of local models with a coarse description of this computer and the engine.
    var groups: [LocalRunGroup] = []
    var versions: [String: String] = [:]
    if kinds.contains(.localRuns), settings.localModels.isEnabled {
        groups = LocalRuns.groups(events: localLog.events(since: now - hours * 3600), settings: settings.localModels)
        if !groups.isEmpty { versions = LocalEngineName.detectVersions(settings: settings.localModels, backends: Set(groups.map { $0.backend })) }
    }
    return (ContributionReport.build(speed: speed, windows: uses, now: now, include: kinds, localRuns: groups, hardware: kinds.contains(.localRuns) ? HardwareInfo.current() : nil, engineVersions: versions), errors)
}

/// After a share, or for `quotapilot compare`: this computer's numbers next to the published community medians.
func printComparison(_ reports: [[String: Any]]) {
    guard let published = CommunityComparison.fetch() else { print("Could not load the community numbers right now."); return }
    let lines = CommunityComparison.compare(mine: reports, with: published)
    if lines.isEmpty {
        print("No community row for your models or plan yet: a row appears once \(published.minPeople) people share the same model or plan" +
              " (\(published.people) sharing in the last \(7) days).")
    } else {
        print("\nCompared with the community:")
        for line in lines { print("  " + CommunityComparison.describe(line)) }
    }
}

func describeReport(_ r: [String: Any]) -> String {
    func n(_ key: String) -> Double { (r[key] as? Double) ?? Double(r[key] as? Int ?? 0) }
    switch r["type"] as? String {
    case "speed":
        let calls = max(n("calls"), 1)
        return "speed   \(r["model"] ?? "?")" + ((r["effort"] as? String).map { " (\($0))" } ?? "")
            + ": \(l.number(n("outputTokens") / max(n("seconds"), 0.1), decimals: 1)) tok/s, \(l.compact(n("outputTokens") / calls)) output tokens/call"
            + " (\(l.number(n("reasoningTokens") / max(n("outputTokens"), 1) * 100, decimals: 0))% reasoning), \(Int(calls)) calls"
    case "quota":
        return "quota   \(r["provider"] ?? "?") \(r["plan"] ?? "?") \(r["window"] ?? "?"): \(l.number(n("percentUsed"), decimals: 1))% used, \(l.compact(n("tokensUsed"))) tokens"
    case "event":
        return "limit   \(r["provider"] ?? "?") \(r["plan"] ?? "?"): limit reached this hour"
    case "localrun":
        return LocalRuns.describe(r)
    default:
        return String(describing: r)
    }
}

func openURL(_ url: String) -> Bool {
    let process = Process()
    #if os(macOS)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = [url]
    #elseif os(Windows)
    // Not cmd.exe: it would treat the "&" between query parameters as a command separator.
    process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\rundll32.exe"); process.arguments = ["url.dll,FileProtocolHandler", url]
    #else
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["xdg-open", url]
    #endif
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}


// MARK: Local models (docs/local-llm.md)

let localLog = LocalLLMLog(url: LocalLLMLog.defaultURL(stateDirectory: stateDirectory))

/// Local model usage for the last `hours`, or nil when the feature is off or nothing was recorded.
func localReport(hours: Double) -> LocalLLMReport? {
    let settings = loadSettings().localModels
    guard settings.isEnabled else { return nil }
    let report = LocalLLMReport(events: localLog.events(since: Date().timeIntervalSince1970 - hours * 3600), reference: settings.referenceModel)
    return report.isEmpty ? nil : report
}

/// The events of the range and of the last 30 days, for the electricity figures.
func localEnergyEvents(hours: Double) -> (range: [LocalLLMEvent], month: [LocalLLMEvent]) {
    let now = Date().timeIntervalSince1970
    let month = localLog.events(since: now - 30 * 86400)
    return (month.filter { $0.t >= now - hours * 3600 }, month)
}

func localLineText(_ line: LocalLLMReport.Line) -> String {
    var parts = [line.requestsKnown ? "\(line.requests) requests" : "requests not reported",
                 "in \(l.compact(line.prompt)) · out \(l.compact(line.completion))"]
    if line.cached > 0 { parts.append("\(l.compact(line.cached)) cached") }
    if let speed = line.promptTokensPerSecond { parts.append("prompt \(l.number(speed, decimals: 0)) tok/s") }
    if let speed = line.generationTokensPerSecond { parts.append("generation \(l.number(speed, decimals: 0)) tok/s" + (line.proxyMeasuredSpeed ? " (proxy-measured)" : "")) }
    if line.activeSeconds >= 1 { parts.append("active " + l.activeTime(minutes: line.activeSeconds / 60)) }
    if line.unmetered > 0 { parts.append("\(line.unmetered) requests without token counts") }
    return "  " + (LocalLLMBackend(rawValue: line.backend)?.displayName ?? line.backend) + " · " + (line.model ?? "unknown model") + ": " + parts.joined(separator: " · ")
}

/// Number and currency formatting follow the system region (the text stays English).
let regional = L10n(.system)

/// Electricity cost of local runs: one line each for the range and the last 30 days, or a hint while no price is set.
func localEnergyLines(range events: [LocalLLMEvent], month: [LocalLLMEvent], reference: String?) -> [String] {
    let energy = loadSettings().localModels.energySettings
    guard energy.hasPrice else { return ["  Electricity: not set. Enter your price per kWh with `quotapilot local config electricity <price per kWh> [--currency CODE]` to see what these runs cost in power."] }
    let report = LocalEnergyReport(events: events, reference: reference, settings: energy)
    guard !report.isEmpty, let cost = report.cost else { return [] }
    var lines = ["  Electricity ≈ " + regional.money(cost, currency: report.currency) + " (\(l.inferenceTime(seconds: report.seconds)) of inference at \(l.number(report.watts, decimals: 0)) W = \(l.number(report.kWh, decimals: 3)) kWh)"]
    if let perMillion = report.costPerMillionTokens {
        var text = "  " + regional.money(perMillion, currency: report.currency) + " per 1M tokens of electricity"
        if let cloud = report.cloudCostPerMillionTokens { text += " (cloud on \(LocalLLMReference.resolve(reference).id): " + regional.money(cloud, currency: report.currency) + ")" }
        else { text += " (cloud: " + l.usd(report.cloudPerMillionTokensUSD ?? 0) + "; set `quotapilot local config rate <\(report.currency) per 1 USD>` to compare in one currency)" }
        lines.append(text)
    }
    let monthly = LocalEnergyReport(events: month, reference: reference, settings: energy)
    if let monthCost = monthly.cost, !monthly.isEmpty { lines.append("  Last 30 days ≈ " + regional.money(monthCost, currency: monthly.currency) + " of electricity") }
    lines.append("  Electricity adds up the measured time of every request, so requests that ran in parallel overstate the kWh.")
    if report.coverage < 0.95 { lines.append("  Only \(l.percent(report.coverage)) of the tokens have a measured time; the rest are not in the electricity figure.") }
    let hardware = HardwareInfo.current()
    if energy.watts == nil { lines.append("  Power is an estimate: \(l.number(report.watts, decimals: 0)) W is typical for \(DevicePower.estimate(for: hardware).basis); macOS cannot read real power without sudo. Change it with `quotapilot local config power <W>`.") }
    return lines
}

func localEnergyJSON(range events: [LocalLLMEvent], month: [LocalLLMEvent], reference: String?) -> [String: Any] {
    let energy = loadSettings().localModels.energySettings
    guard energy.hasPrice else { return ["configured": false, "note": "Set the electricity price with `quotapilot local config electricity <price per kWh>`."] }
    func object(_ report: LocalEnergyReport) -> [String: Any] {
        ["inferenceSeconds": report.seconds, "kWh": report.kWh, "cost": report.cost ?? NSNull(), "costPerMillionTokens": report.costPerMillionTokens ?? NSNull(),
         "cloudCostSameCurrency": report.cloudCost ?? NSNull(), "cloudCostPerMillionTokensSameCurrency": report.cloudCostPerMillionTokens ?? NSNull(),
         "cloudCostUSD": report.cloudCostUSD, "tokensMeasured": report.measuredTokens, "tokensTotal": report.totalTokens]
    }
    let range = LocalEnergyReport(events: events, reference: reference, settings: energy)
    return ["configured": true, "currency": range.currency, "pricePerKWh": energy.pricePerKWh ?? NSNull(), "watts": range.watts, "wattsIsEstimate": energy.watts == nil,
            "range": object(range), "last30Days": object(LocalEnergyReport(events: month, reference: reference, settings: energy)),
            "note": "Estimate: power is a typical value for this computer unless set; macOS cannot read real power without administrator rights."]
}

func localReportText(_ report: LocalLLMReport) -> [String] {
    var lines = ["Local models: \(report.requestsKnown ? "\(report.requests) requests · " : "")in \(l.compact(report.prompt)) · out \(l.compact(report.completion))"
                 + " · ≈ \(l.usd(report.costUSD)) if run on \(report.reference.id) (hypothetical: running locally costs nothing)"]
    lines += report.lines.map(localLineText)
    if report.unmetered > 0 { lines.append("  \(report.unmetered) requests had no token counts: enable stream_options.include_usage in the client.") }
    return lines
}

func localReportJSON(_ report: LocalLLMReport) -> [String: Any] {
    func line(_ x: LocalLLMReport.Line) -> [String: Any] {
        ["backend": x.backend, "model": x.model ?? NSNull(), "requests": x.requestsKnown ? x.requests as Any : NSNull(), "requestsWithoutTokenCounts": x.unmetered,
         "promptTokens": x.prompt, "cachedTokens": x.cached, "completionTokens": x.completion, "reasoningTokens": x.reasoning,
         "promptTokensPerSecond": x.promptTokensPerSecond ?? NSNull(), "generationTokensPerSecond": x.generationTokensPerSecond ?? NSNull(),
         "speedMeasuredByProxy": x.proxyMeasuredSpeed, "activeSeconds": x.activeSeconds, "hypotheticalCloudCostUSD": x.costUSD]
    }
    return ["referenceModel": report.reference.id, "hypotheticalCloudCostUSD": report.costUSD, "promptTokens": report.prompt, "cachedTokens": report.cached,
            "completionTokens": report.completion, "requests": report.requestsKnown ? report.requests as Any : NSNull(), "requestsWithoutTokenCounts": report.unmetered,
            "byModel": report.lines.map(line),
            "note": "Hypothetical: what the same tokens would cost on the reference cloud model. Running locally costs nothing."]
}

func pollStateText(_ state: LocalPollState) -> String {
    switch state {
    case .off: return "off"
    case .notRunning: return "not detected"
    case .metricsUnavailable: return "answers, but /metrics is unavailable (start llama-server with --metrics)"
    case .needsKey: return "needs the API key (QUOTAPILOT_OMLX_API_KEY)"
    case .unsupported: return "answers, but not with usage data"
    case .proxiedElsewhere: return "metered by a proxy running in another QuotaPilot process"
    case .otherProcess: return "polled by another QuotaPilot process (the app or `quotapilot local poll`)"
    case .ok(let port): return "reading usage from port \(port)"
    }
}

func runLocalCommand(_ rest: [String]) -> Never {
    var settings = loadSettings()
    func save(_ change: (inout LocalLLMSettings) -> Void) {
        var local = settings.localModels
        change(&local)
        if let problem = local.validate() { fail(problem) }
        settings.localModels = local
        saveCLISettings(settings)
    }
    func backend(_ name: String?) -> LocalLLMBackend {
        guard let name, let value = LocalLLMBackend(rawValue: name) else {
            fail("backend must be one of: " + LocalLLMBackend.allCases.map(\.rawValue).joined(separator: ", "), code: 2)
        }
        return value
    }
    func runLoopForever(_ stop: @escaping () -> Void) -> Never {
        #if !os(Windows)
        let queue = DispatchQueue(label: "quotapilot.local.signals")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { stop(); exit(0) }
            source.resume()
            watchSignalSources.append(source)
        }
        #endif
        while true { RunLoop.main.run(until: Date().addingTimeInterval(3600)) }
    }
    if !LocalLLMLog.isSupported {
        if wantsJSON { printJSON(["supported": false, "message": LocalLLMLog.unsupportedMessage]) } else { print(LocalLLMLog.unsupportedMessage) }
        exit(["poll", "proxy"].contains(rest.first ?? "status") ? 1 : 0)
    }
    switch rest.first ?? "status" {
    case "status":
        let local = settings.localModels
        // Report only: no proxy is started and no lock is taken.
        let service = LocalLLMService(log: localLog)
        let probed = service.probe(settings: local)
        func pollText(_ b: LocalLLMBackend) -> String { local.isEnabled && b.hasPoller && !local.proxyEnabled(b) ? pollStateText(probed[b] ?? .off) : "off" }
        if wantsJSON {
            var backends: [String: Any] = [:]
            for b in LocalLLMBackend.allCases {
                backends[b.rawValue] = ["proxy": local.proxyEnabled(b), "proxyURL": local.proxyURL(b), "poll": pollText(b)]
            }
            printJSON(["enabled": local.isEnabled, "referenceModel": local.reference, "backends": backends])
        } else {
            print("Local models: " + (local.isEnabled ? "on" : "off (quotapilot local config on)") + " · reference cloud model: \(local.reference) (hypothetical cost)")
            for b in LocalLLMBackend.allCases {
                var text = b.displayName.padding(toLength: 10, withPad: " ", startingAt: 0)
                if b.hasPoller { text += "poll: " + pollText(b) + " · " }
                else { text += "needs the proxy · " }
                text += "proxy " + (local.proxyEnabled(b) ? "on \(local.proxyURL(b)) → \(local.upstreamHost(b)):\(local.upstreamPort(b))" : "off")
                print(text)
            }
        }
        exit(0)
    case "stats":
        let range = hours
        let events = localLog.events(since: Date().timeIntervalSince1970 - range * 3600)
        let report = LocalLLMReport(events: events, reference: settings.localModels.referenceModel)
        let month = localLog.events(since: Date().timeIntervalSince1970 - 30 * 86400)
        if wantsJSON {
            var json = localReportJSON(report)
            json["electricity"] = localEnergyJSON(range: events, month: month, reference: settings.localModels.referenceModel)
            printJSON(json)
        }
        else if report.isEmpty { print("No local model usage recorded in the last \(hoursLabel(range)). " + (settings.localModels.isEnabled ? "" : "Turn it on with `quotapilot local config on`.")) }
        else {
            for line in localReportText(report) { print(line) }
            for line in localEnergyLines(range: events, month: month, reference: settings.localModels.referenceModel) { print(line) }
        }
        exit(0)
    case "hardware":
        let hardware = HardwareInfo.current()
        let estimate = DevicePower.estimate(for: hardware)
        let energy = settings.localModels.energySettings
        if wantsJSON {
            printJSON(["os": hardware.sharedOS.family, "osMajor": hardware.sharedOS.major, "cpu": hardware.cpuName ?? NSNull(), "chip": hardware.sharedChip ?? NSNull(),
                       "memoryGiB": hardware.memoryGiB, "memoryTier": hardware.sharedMemoryTier, "gpuCores": hardware.gpuCores ?? NSNull(),
                       "typicalWatts": estimate.watts, "wattsUsed": energy.resolvedWatts(hardware), "currency": energy.resolvedCurrency(), "pricePerKWh": energy.pricePerKWh ?? NSNull()])
        } else {
            print("This computer: " + (hardware.cpuName ?? "unknown CPU") + " · \(l.number(hardware.memoryGiB, decimals: 0)) GB memory" + (hardware.gpuCores.map { " · \($0) GPU cores" } ?? "") + " · " + hardware.os)
            print("Typical power under local inference: \(l.number(estimate.watts, decimals: 0)) W (estimate for \(estimate.basis); not measured)")
            print("Electricity: " + (energy.hasPrice ? "\(energy.pricePerKWh ?? 0) \(energy.resolvedCurrency()) per kWh, \(l.number(energy.resolvedWatts(hardware), decimals: 0)) W" : "price not set"))
        }
        exit(0)
    case "config":
        let args = Array(rest.dropFirst())
        switch args.first ?? "show" {
        case "on", "off": save { $0.enabled = args[0] == "on" }; print("local models = \(args[0])")
        case "reference":
            guard args.count == 2, ModelPrices.price(for: args[1]) != nil else {
                fail("usage: quotapilot local config reference <model id from the price table, e.g. \(LocalLLMReference.defaultModel)>", code: 2)
            }
            save { $0.referenceModel = args[1] }; print("reference = \(args[1])")
        case "electricity":
            // `electricity 0.25 [--currency EUR]` sets the price per kWh; `electricity clear` removes it.
            guard args.count >= 2 else { fail("usage: quotapilot local config electricity <price per kWh | clear> [--currency CODE]", code: 2) }
            if args[1] == "clear" { save { $0.energySettings.pricePerKWh = nil }; print("electricity price cleared"); break }
            guard let price = Double(args[1].replacingOccurrences(of: ",", with: ".")), price > 0, EnergySettings.validate(price: price) == nil else {
                fail("the price per kWh must be a positive number (for example 0.25)", code: 2)
            }
            if let code = option("--currency") {
                if let bad = EnergySettings.validate(currency: code) { fail(bad, code: 2) }
                save { $0.energySettings.currency = code.uppercased() }
            }
            save { $0.energySettings.pricePerKWh = price }
            print("electricity = \(price) \(settings.localModels.energySettings.resolvedCurrency()) per kWh")
        case "currency":
            guard args.count == 2, EnergySettings.validate(currency: args[1]) == nil else { fail("usage: quotapilot local config currency <ISO code, e.g. USD, EUR, JPY>", code: 2) }
            save { $0.energySettings.currency = args[1].uppercased() }; print("currency = \(args[1].uppercased())")
        case "power":
            if args.count == 2, args[1] == "auto" { save { $0.energySettings.watts = nil }; print("power = typical value for this computer"); break }
            guard args.count == 2, let watts = Double(args[1]), EnergySettings.validate(watts: watts) == nil else { fail("usage: quotapilot local config power <watts 1-5000 | auto>", code: 2) }
            save { $0.energySettings.watts = watts }; print("power = \(watts) W")
        case "rate":
            if args.count == 2, args[1] == "clear" { save { $0.energySettings.usdRate = nil }; print("exchange rate cleared"); break }
            guard args.count == 2, let rate = Double(args[1].replacingOccurrences(of: ",", with: ".")), EnergySettings.validate(rate: rate) == nil else { fail("usage: quotapilot local config rate <units of your currency per 1 USD | clear>", code: 2) }
            save { $0.energySettings.usdRate = rate }; print("1 USD = \(rate) \(settings.localModels.energySettings.resolvedCurrency())")
        case "proxy":
            guard args.count == 3, ["on", "off"].contains(args[2]) else { fail("usage: quotapilot local config proxy <backend> <on|off> [--listen N] [--upstream N] [--upstream-host H]", code: 2) }
            let b = backend(args[1])
            save { local in
                local.update(b) { config in
                    config.proxy = args[2] == "on"
                    if let text = option("--listen"), let port = Int(text) { config.listenPort = port }
                    if let text = option("--upstream"), let port = Int(text) { config.upstreamPort = port }
                    if let host = option("--upstream-host") { config.upstreamHost = host }
                }
            }
            print("\(b.displayName) proxy = \(args[2]) (\(settings.localModels.proxyURL(b)))")
        default:
            print("local models: " + (settings.localModels.isEnabled ? "on" : "off"))
            print("reference: " + settings.localModels.reference)
            let energy = settings.localModels.energySettings
            print("electricity: " + (energy.hasPrice ? "\(energy.pricePerKWh ?? 0) \(energy.resolvedCurrency()) per kWh" : "not set") + " · power: " + (energy.watts.map { "\($0) W" } ?? "typical (\(energy.resolvedWatts()) W)"))
            for b in LocalLLMBackend.allCases { print("\(b.rawValue) proxy: " + (settings.localModels.proxyEnabled(b) ? "on" : "off")) }
        }
        exit(0)
    case "poll":
        let service = LocalLLMService(log: localLog, lockDirectory: stateDirectory)
        guard service.acquirePollLock() else { fail("Another QuotaPilot process (the app or another `quotapilot local poll`) is already polling.") }
        var local = settings.localModels
        local.enabled = true   // the command is the opt-in
        for b in LocalLLMBackend.allCases where local.proxyEnabled(b) { local.update(b) { $0.proxy = false } }
        service.apply(local)
        localLog.compact(now: Date().timeIntervalSince1970)
        let once = arguments.contains("--once")
        while true {
            let events = service.pollOnce()
            for event in events { print("\(event.backend) \(event.model ?? "?"): +\(l.compact(event.prompt)) in, +\(l.compact(event.completion)) out") }
            if once {
                for b in LocalLLMBackend.allCases where b.hasPoller { print("\(b.displayName): " + pollStateText(service.pollState(b))) }
                exit(0)
            }
            fflush(stdout)
            RunLoop.main.run(until: Date().addingTimeInterval(60))
        }
    case "proxy":
        guard LocalSockets.isSupported else { fail("The metering proxy is not available on this platform (macOS and Linux only).") }
        var local = settings.localModels
        var wanted: [LocalLLMBackend] = []
        if let name = option("--backend") {
            let b = backend(name)
            local.update(b) { config in
                config.proxy = true
                if let text = option("--listen"), let port = Int(text) { config.listenPort = port }
                if let text = option("--upstream"), let port = Int(text) { config.upstreamPort = port }
                if let host = option("--upstream-host") { config.upstreamHost = host }
            }
            wanted = [b]
        } else {
            wanted = LocalLLMBackend.allCases.filter(local.proxyEnabled)
        }
        guard !wanted.isEmpty else { fail("No proxy is configured. Use `quotapilot local proxy --backend ollama` or `quotapilot local config proxy ollama on`.", code: 2) }
        if let problem = local.validate() { fail(problem) }
        local.enabled = true   // running the proxy is the opt-in; polling stays off because every backend named here is proxied
        let service = LocalLLMService(log: localLog, lockDirectory: stateDirectory)
        localLog.compact(now: Date().timeIntervalSince1970)
        service.apply(local)
        for b in wanted {
            if let error = service.proxyError(b) { fail("\(b.displayName): \(error)") }
            print("\(b.displayName): point your client at \(local.proxyURL(b)) (forwarding to \(local.upstreamHost(b)):\(local.upstreamPort(b)))")
        }
        print("Only token counts, model ids and timings are recorded, in \(localLog.url.path). Ctrl-C to stop.")
        fflush(stdout)
        runLoopForever { service.stop() }
    default:
        fail("usage: quotapilot local <status|stats|hardware|poll|proxy|config>", code: 2)
    }
}

// MARK: Commands

let usage = """
quotapilot \(version) — plan quota, token usage and agent routing for Codex and Claude Code

USAGE
  quotapilot [status] [--json] [--hours N]   Quota, tokens (default last 24 h) and routing
  quotapilot watch [--interval SECONDS]      Refresh status in the terminal (default 60 s)
  quotapilot route <web|review|plan|implement> [--json]
                                             Print the agent for a kind of task (exit 3 if none)
  quotapilot stats [--hours N] [--json]      Token totals, equivalent API cost, cache hit rate and shares by agent and model from local logs
  quotapilot local <status|stats|hardware|poll|proxy|config>
                                             Local model usage (Ollama, LM Studio, llama.cpp, oMLX); see docs/local-llm.md
  quotapilot config [show]                   Show router mode and task rules
  quotapilot config <claude-plan|agent-logs> <on|off>
                                             Choose credential access and local log collection
  quotapilot config mode <auto|preferCodex|preferClaude>
  quotapilot config rule <web|review|plan|implement> <auto|codex|claude>
  quotapilot share [--hours N] [--only speed,promptCache,quota,limitEvents,localRuns] [--json] [--yes] | --forget
                                             Preview anonymous speed and quota numbers and, only if
                                             you confirm, send them anonymously to AI Quota Watch.
                                             `share --yes` in cron shares daily.
                                             `share --forget` deletes everything this computer sent.
  quotapilot compare [--hours N]             Your speed and plan quota next to the community medians (sends nothing)
  quotapilot open [--link]                   macOS: start the menu bar app (--link also adds it to ~/Applications)
  quotapilot version

On macOS the router mode and rules come from the QuotaPilot app when it is installed;
elsewhere they are stored in \(configURL.path).
"""

// Option values such as `--hours 6` or `--only speed` are not words.
let words = CLIArguments.positional(arguments)
let command: String = {
    if arguments.contains("--help") { return "help" }
    if arguments.contains("--version") { return "version" }
    return words.first ?? "status"
}()
let hours: Double = {
    guard let text = option("--hours") else { return 24 }
    guard let value = Double(text), value.isFinite, value > 0, value <= 744 else { fail("--hours must be a number between 0 and 744") }
    return value
}()

switch command {
case "help", "-h":
    print(usage)
case "version":
    print("quotapilot " + version)
case "open":
    // Starts the menu bar app this tool ships inside (Homebrew keeps it in the Cellar).
    // `open --link` also puts a link in ~/Applications so QuotaPilot is listed there (Finder, Dock).
    #if os(macOS)
    let tool = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
    guard let app = ProjectLinks.appBundle(containing: tool) else {
        fail("This quotapilot is not inside QuotaPilot.app. Install the app with Homebrew, or open it from where you built it.")
    }
    if arguments.contains("--link") {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let link = folder.appendingPathComponent("QuotaPilot.app")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // `brew upgrade` removes the versioned Cellar folder, so link the stable opt path when there is one.
        let target = ProjectLinks.stableHomebrewApp(for: app) ?? app
        // Replace only an earlier link; never a real app someone installed there.
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            if existing != target.path { try? FileManager.default.removeItem(at: link) }
        } else if FileManager.default.fileExists(atPath: link.path) {
            fail(link.path + " is already an app, not a link; it was left alone.")
        }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil {
            do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target) }
            catch { fail("Could not create " + link.path + ": " + error.localizedDescription) }
        }
        print("Linked " + link.path)
    }
    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launcher.arguments = [app.path]
    do { try launcher.run(); launcher.waitUntilExit() } catch { fail("Could not open " + app.path + ": " + error.localizedDescription) }
    if launcher.terminationStatus != 0 { fail("Could not open " + app.path) }
    print("Opened " + app.path + ". Look for the gauge icon in the menu bar.")
    #else
    fail("The menu bar app is for macOS. On this system use `quotapilot status` or `quotapilot watch`.", code: 2)
    #endif
case "status":
    let snapshot = collect(tokenHours: hours)
    if wantsJSON { printJSON(statusObject(snapshot)) } else { print(renderText(snapshot)) }
case "watch":
    let interval = max(15, Double(option("--interval") ?? "") ?? 60)
    let session = CodexSession(keepAlive: true)
    watchSession = session
    #if !os(Windows)
    // Ctrl-C, kill and a closed terminal would otherwise leave the Codex app server this session started running.
    // The handlers run on their own queue: the main thread may be blocked inside a refresh.
    let signalQueue = DispatchQueue(label: "quotapilot.signals")
    for (number, code) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143)), (SIGHUP, Int32(129))] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler {
            if let pid = session.client.childProcessID { kill(pid, SIGTERM) }
            exit(code)
        }
        source.resume()
        watchSignalSources.append(source)
    }
    #endif
    while true {
        let snapshot = collect(tokenHours: hours)
        print("\u{1B}[2J\u{1B}[H" + renderText(snapshot) + "\n\nRefreshing every \(Int(interval)) s · Ctrl-C to stop")
        // Keep the run loop going (not Thread.sleep): the client's pipes and timers live on it.
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
case "route":
    guard let raw = words.dropFirst().first,
          let kind = TaskKind(rawValue: raw) else { fail("usage: quotapilot route <web|review|plan|implement>", code: 2) }
    let snapshot = collect(tokenHours: hours, includeTokens: false)
    let mode = snapshot.settings.routerMode ?? .auto
    let pick = AgentRouter.assign(kind, rules: snapshot.settings.taskRouting, mode: mode, items: snapshot.windows, now: snapshot.now)
    if wantsJSON {
        printJSON(["task": kind.rawValue, "agent": pick.agent ?? NSNull(), "reason": pick.reason, "router": routerObject(snapshot)])
    } else {
        print(pick.agent ?? "none")
    }
    exit(pick.agent == nil ? 3 : 0)
case "stats":
    let summary = tokenSummary(hours: hours)
    let total = summary.values.reduce(into: TokenBreakdown()) { $0.add($1) }
    let report = usageReport(hours: hours)
    if wantsJSON {
        let speed = Dictionary(grouping: speedSamples, by: \.provider).compactMapValues { samples -> [String: Any]? in
            guard let s = OutputSpeedSummary(samples) else { return nil }
            return ["tokensPerSecond": s.tokensPerSecond, "medianTokensPerSecond": s.medianTokensPerSecond, "calls": s.calls, "outputTokens": s.outputTokens, "seconds": s.seconds]
        }
        var object: [String: Any] = ["hours": hours, "total": breakdownJSON(total), "providers": summary.mapValues(breakdownJSON), "outputSpeed": speed,
                                     "usage": reportJSON(report)]
        if let local = localReport(hours: hours) {
            var json = localReportJSON(local)
            let events = localEnergyEvents(hours: hours)
            json["electricity"] = localEnergyJSON(range: events.range, month: events.month, reference: loadSettings().localModels.referenceModel)
            object["local"] = json
        }
        printJSON(object)
    } else {
        print("Tokens in the last \(hoursLabel(hours)): \(l.compact(total.total)) · ≈\(l.compact(total.total / hours))/h · ≈\(l.compact(total.total / hours / 3600))/s")
        print("  " + breakdownText(total))
        for (provider, usage) in summary.sorted(by: { $0.value.total > $1.value.total }) {
            print(providerName(provider).padding(toLength: 9, withPad: " ", startingAt: 0) + l.compact(usage.total) + "  " + breakdownText(usage))
        }
        for line in reportText(report) { print(line) }
        for line in speedText() { print("Output speed  " + line) }
        print("  Output speed = output tokens (incl. reasoning) ÷ model-call time. The time includes prefill and time to first token, so it is a lower bound on decode (TG) tok/s.")
        if let local = localReport(hours: hours) {
            for line in localReportText(local) { print(line) }
            let events = localEnergyEvents(hours: hours)
            for line in localEnergyLines(range: events.range, month: events.month, reference: loadSettings().localModels.referenceModel) { print(line) }
        }
    }
case "share":
    if arguments.contains("--forget") {
        // Right to erasure: the collector deletes everything this computer's anonymous id sent.
        // Like the menu bar app, stop daily sharing first: otherwise the next scheduled run would send new reports.
        var forgetSettings = loadSettings()
        let wasSharing = forgetSettings.autoShareEnabled
        if wasSharing { forgetSettings.autoShareEnabled = false; saveCLISettings(forgetSettings) }
        switch ShareSubmitter.forgetAnonymous() {
        case .success(let n):
            print("Deleted \(n) stored report batches from the AI Quota Watch collector. Public stats drop them at the next rebuild (within 6 hours).")
            if wasSharing { print("Daily sharing was turned off. Scripts or schedules that run `quotapilot share --yes` still send new reports until you remove them.") }
            exit(0)
        case .failure(let error): fail("Could not delete: " + error.localizedDescription)
        }
    }
    let (reports, errors) = shareReports(hours: hours)
    let data = (try? JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    let json = String(decoding: data, as: UTF8.self)
    if wantsJSON { print(json); exit(0) }  // preview only, never sends
    for (agent, error) in errors.sorted(by: { $0.key < $1.key }) { print(providerName(agent) + ": " + cliText(error)) }
    guard !reports.isEmpty else {
        print("Nothing to share yet. Speed needs 3 calls per model and effort in the last \(hoursLabel(hours)); quota needs at least 1% of a 5-hour or weekly window used; local runs (--only localRuns) need local models switched on and 3 timed requests per model.")
        exit(0)
    }
    print("QuotaPilot can share these anonymous numbers with AI Quota Watch:\n")
    for report in reports { print("  " + describeReport(report)) }
    print("\nExactly what would be sent:\n\(json)\n")
    if reports.contains(where: { $0["type"] as? String == "localrun" }) {
        print("Local runs (you chose to include them) add this computer's chip, memory size, operating system and the inference engine, in coarse buckets, so the website can rank local models by hardware.")
    }
    print("No paths, project names, prompts or account ids are included. Times are rounded to the hour.")
    print("This sends the numbers anonymously to the AI Quota Watch collector: no account, and it keeps only a hashed id of this computer.")
    if arguments.contains("--github") || arguments.contains("--submit") {
        fail("Sharing is anonymous only; reports are no longer filed as GitHub issues.", code: 2)
    }
    if !arguments.contains("--yes") {
        print("\nShare these numbers? [y/N] ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), answer == "y" || answer == "yes" else {
            print("Nothing was shared."); exit(0)
        }
    }
    switch ShareSubmitter.postAnonymous(reports: reports) {
    case .success(let n): print("Shared \(n) data points anonymously. Thank you.")
        print("See the community numbers: " + ProjectLinks.community.absoluteString)
        printComparison(reports)
    case .failure(let error): fail("Could not share: " + error.localizedDescription)
    }
case "compare":
    // Downloads the public community statistics and compares; sends nothing.
    let (reports, errors) = shareReports(hours: hours)
    for (agent, error) in errors.sorted(by: { $0.key < $1.key }) { print(providerName(agent) + ": " + cliText(error)) }
    if reports.isEmpty { print("Nothing to compare yet: speed needs 3 calls per model in the last \(hoursLabel(hours)).") }
    else { printComparison(reports) }
    print("\nThe community numbers come only from people who share. `quotapilot share` previews what you would send.")

case "local":
    runLocalCommand(Array(words.dropFirst()))
case "config":
    var settings = loadSettings()
    let rest = Array(arguments.drop { $0 != "config" }.dropFirst())
    switch rest.first ?? "show" {
    case "claude-plan", "agent-logs":
        guard rest.count == 2, ["on", "off"].contains(rest[1]) else {
            fail("usage: quotapilot config <claude-plan|agent-logs> <on|off>", code: 2)
        }
        if rest[0] == "claude-plan" { settings.claudePlanEnabled = rest[1] == "on" }
        else { settings.agentLogsEnabled = rest[1] == "on" }
        saveCLISettings(settings); print("\(rest[0]) = \(rest[1])")
    case "mode":
        guard rest.count >= 2, let mode = RouterMode(rawValue: rest[1]) else { fail("usage: quotapilot config mode <auto|preferCodex|preferClaude>", code: 2) }
        settings.routerMode = mode; saveCLISettings(settings); print("mode = \(mode.rawValue)")
    case "rule":
        guard rest.count >= 3, let kind = TaskKind(rawValue: rest[1]), let who = TaskAssignee(rawValue: rest[2]) else {
            fail("usage: quotapilot config rule <web|review|plan|implement> <auto|codex|claude>", code: 2)
        }
        var rules = settings.taskRouting; rules[kind] = who; settings.taskRouting = rules
        saveCLISettings(settings); print("\(kind.rawValue) → \(who.rawValue)")
    default:
        print("claude-plan: " + (settings.claudePlanEnabled ? "on" : "off"))
        print("agent-logs: " + (settings.agentLogsEnabled ? "on" : "off"))
        print("mode: " + (settings.routerMode ?? .auto).rawValue)
        for kind in TaskKind.allCases { print("rule \(kind.rawValue): " + (settings.taskRouting[kind] ?? .auto).rawValue) }
        #if os(macOS)
        print("(macOS: the QuotaPilot app's settings take precedence when it is installed)")
        #endif
    }
default:
    fail("Unknown command \(command)\n\n" + usage, code: 2)
}
