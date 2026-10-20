import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct QuotaWindow: Codable, Equatable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?
    public var validUsedPercent: Double? {
        guard let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
        return usedPercent
    }
}
public struct Bucket: Codable {
    public let limitId: String?
    public let limitName: String?
    public let planType: String?
    public let primary: QuotaWindow?
    public let secondary: QuotaWindow?
    public var rateLimitReachedType: String? = nil
}
public struct LimitsResponse: Codable {
    public let rateLimits: Bucket?
    public let rateLimitsByLimitId: [String: Bucket]?
    public let accountId: String?
    public func windows() -> [WindowItem] {
        let buckets: [String: Bucket]
        if let map = rateLimitsByLimitId, !map.isEmpty { buckets = map }
        else if let legacy = rateLimits { buckets = [legacy.limitId ?? "codex": legacy] }
        else { buckets = [:] }
        return buckets.keys.sorted { a, b in
            if a == "codex" { return b != "codex" }; if b == "codex" { return false }; return a < b
        }.flatMap { id -> [WindowItem] in
            let b = buckets[id]!
            let name = id == "codex" ? "Codex" : (b.limitName ?? id).replacingOccurrences(of: "GPT-5.3-Codex-Spark", with: "Spark")
            return [("primary", b.primary), ("secondary", b.secondary)].compactMap { slot, window in
                guard let w = window else { return nil }
                return WindowItem(id: id + ":" + slot, name: name, window: w, planType: b.planType,
                                  limitReached: !(b.rateLimitReachedType ?? "").isEmpty)
            }
        }
    }
}
public struct WindowItem {
    public let id: String
    public let name: String
    public let window: QuotaWindow
    public var planType: String? = nil
    /// The backend reports this bucket as rate-limited, independently of `usedPercent`.
    public var limitReached: Bool = false
    public var title: String { name + " · " + durationLabel(window.windowDurationMins) }
}
public func durationLabel(_ minutes: Int?) -> String {
    guard let m = minutes, m > 0 else { return "週期未知" }
    if m % 10080 == 0 { return "\(m / 10080)週" }
    if m % 1440 == 0 { return "\(m / 1440)天" }
    if m % 60 == 0 { return "\(m / 60)小時" }
    return "\(m)分鐘"
}
public func countdown(_ reset: Double?, now: Double) -> String {
    guard let reset, reset.isFinite else { return "重置時間未知" }
    let delta = reset - now
    guard delta > 0 else { return "等待重置確認" }
    let s = Int(min(delta, 315360000))
    if s >= 86400 { return "\(s / 86400)天 \(s % 86400 / 3600)時 \(s % 3600 / 60)分" }
    return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}
public struct Sample: Codable {
    public let timestamp: Double
    public let used: Double
    public let reset: Double?
    public let duration: Int?
    public var planType: String? = nil
}
public struct Rate {
    public let perHour: Double
    public let observedSeconds: Double
    public func value(per unit: TimeUnit) -> Double { perHour * unit.seconds / 3600 }
}
public struct History: Codable {
    public private(set) var account: String?
    public private(set) var series: [String: [Sample]] = [:]
    public init() {}
    public mutating func record(account newAccount: String, items: [WindowItem], now: Double) {
        if account != newAccount { series = [:]; account = newAccount }
        for key in Array(series.keys) {
            series[key] = series[key]?.filter { $0.timestamp >= now - historyRetentionSeconds && $0.timestamp <= now }
        }
        let present = Set(items.map(\.id))
        for key in Array(series.keys) where !present.contains(key) { series.removeValue(forKey: key) }
        for item in items {
            guard let used = item.window.usedPercent, used.isFinite, (0...100).contains(used) else {
                series.removeValue(forKey: item.id); continue
            }
            var samples = series[item.id] ?? []
            if let last = samples.last {
                let gap = now - last.timestamp
                if gap < 0 || gap > 300 || used < last.used || last.reset != item.window.resetsAt || last.duration != item.window.windowDurationMins || last.planType != item.planType {
                    samples = []
                } else if gap == 0 { samples.removeLast() }
            }
            samples.append(Sample(timestamp: now, used: used, reset: item.window.resetsAt, duration: item.window.windowDurationMins, planType: item.planType))
            series[item.id] = samples
        }
    }
    public func rate(for id: String, now: Double, lookback: Double = 3600) -> Rate? {
        guard let samples = series[id], !samples.isEmpty, let last = samples.last,
              now >= last.timestamp, now - last.timestamp <= 300,
              last.reset.map({ $0 > now }) ?? true else { return nil }
        return observedRate(samples.map { ($0.timestamp, $0.used) }, lookback: lookback)
    }
}

// Keep the entire card visible after a monitor is removed or its resolution changes.
public func visibleOrigin(for frame: CGRect, screens: [CGRect]) -> CGPoint {
    guard let first = screens.first else { return frame.origin }
    let screen = screens.max { a, b in
        let ai = a.intersection(frame), bi = b.intersection(frame)
        return (ai.isNull ? 0 : ai.width*ai.height) < (bi.isNull ? 0 : bi.width*bi.height)
    } ?? first
    return CGPoint(x: max(screen.minX, min(frame.minX, screen.maxX-frame.width)),
                   y: max(screen.minY, min(frame.minY, screen.maxY-frame.height)))
}

public let historyRetentionSeconds: Double = 31 * 86400

public enum TimeUnit: String, Codable, CaseIterable {
    case minute, hour, day, second
    public var seconds: Double {
        switch self { case .second: return 1; case .minute: return 60; case .hour: return 3600; case .day: return 86400 }
    }
    /// Observation windows are whole minutes or longer; rates can also be shown per second.
    public static let intervalUnits: [TimeUnit] = [.minute, .hour, .day]
    public static let rateUnits: [TimeUnit] = [.second, .minute, .hour, .day]
}
public enum WidgetLanguage: String, Codable, CaseIterable {
    case system, zhHant = "zh-Hant", zhHans = "zh-Hans", english = "en"
    case japanese = "ja", korean = "ko", spanish = "es", french = "fr", german = "de", portuguese = "pt-BR", italian = "it"
    public var nativeName: String {
        switch self {
        case .system: return "System"
        case .zhHant: return "繁體中文"
        case .zhHans: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .portuguese: return "Português (Brasil)"
        case .italian: return "Italiano"
        }
    }
}
public struct RGBColor: Codable, Equatable {
    public var red: Int; public var green: Int; public var blue: Int
    public init(_ red: Int, _ green: Int, _ blue: Int) { self.red = red; self.green = green; self.blue = blue }
    public var isValid: Bool { [red, green, blue].allSatisfy { (0...255).contains($0) } }
}
public struct Customization: Codable, Equatable {
    public var multiple = false
    public var windowIDs: [String] = []
    public var customColors = false
    public var foreground = RGBColor(240, 240, 245)
    public var background = RGBColor(28, 30, 36)
    public var energySaver = false
    public var bridges = false
    public init() {}
}
public struct WidgetSettings: Codable, Equatable {
    public var language: WidgetLanguage = .system
    public var intervalValue: Int = 1
    public var intervalUnit: TimeUnit = .hour
    public var rateUnit: TimeUnit = .hour
    public var customization: Customization? = nil
    public var quotaAlerts: Bool? = nil
    public var autoContinue: Bool? = nil
    public var agentLogs: Bool? = nil
    public var autoConnect: Bool? = nil
    public var routerMode: RouterMode? = nil
    public var cardStyle: CardStyle? = nil
    public var taskRules: [String: String]? = nil
    public var quotaSort: QuotaSort? = nil
    /// System readings shown on the card (none by default) and the temperature unit ("c" or "f").
    public var systemFields: [String]? = nil
    public var temperatureUnit: String? = nil
    public func showsSystem(_ field: SystemField) -> Bool { (systemFields ?? []).contains(field.rawValue) }
    public var usesFahrenheit: Bool { temperatureUnit == "f" }
    /// Card fields the user turned off (all are shown by default).
    public var hiddenFields: [String]? = nil
    public func shows(_ field: CardField) -> Bool { !(hiddenFields ?? []).contains(field.rawValue) }
    public mutating func set(_ field: CardField, visible: Bool) {
        var hidden = Set(hiddenFields ?? [])
        if visible { hidden.remove(field.rawValue) } else { hidden.insert(field.rawValue) }
        hiddenFields = hidden.isEmpty ? nil : hidden.sorted()
    }
    /// Providers shown first, in this order (e.g. ["claude"]).
    public var pinnedProviders: [String]? = nil
    public var taskRouting: [TaskKind: TaskAssignee] {
        get { Dictionary(uniqueKeysWithValues: TaskKind.allCases.map { ($0, TaskAssignee(rawValue: taskRules?[$0.rawValue] ?? "") ?? .auto) }) }
        set { taskRules = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value.rawValue) }) }
    }
    /// Connect detected agents (status-line bridges, provider imports, DeepSeek balance) without a manual step.
    public var autoConnectEnabled: Bool {
        get { autoConnect ?? true }
        set { autoConnect = newValue }
    }
    /// Resume an interrupted Codex session with `codex exec resume` once a full quota window resets.
    public var autoContinueEnabled: Bool {
        get { autoContinue ?? false }
        set { autoContinue = newValue }
    }
    /// Read token counts from local Codex and Claude Code session logs.
    public var agentLogsEnabled: Bool {
        get { agentLogs ?? true }
        set { agentLogs = newValue }
    }
    public var quotaAlertsEnabled: Bool {
        get { quotaAlerts ?? false }
        set { quotaAlerts = newValue }
    }
    public var options: Customization {
        get { customization ?? Customization() }
        set { customization = newValue }
    }
    public init() {}
    public var lookback: Double { Double(intervalValue) * intervalUnit.seconds }
    public var isValid: Bool { intervalValue > 0 && (60...30*86400).contains(lookback) && options.foreground.isValid && options.background.isValid }
}

private func observedRate(_ samples: [(Double, Double)], lookback: Double) -> Rate? {
    guard lookback.isFinite, (60...30*86400).contains(lookback),
          let first = samples.first, let last = samples.last else { return nil }
    let start = max(first.0, last.0-lookback)
    let span = last.0-start
    guard span >= min(300, lookback) else { return nil }
    var baseline = first.1
    for i in 1..<samples.count {
        let a = samples[i-1], b = samples[i]
        if a.0 <= start && b.0 >= start && b.0 > a.0 {
            baseline = a.1 + (b.1-a.1) * (start-a.0)/(b.0-a.0)
            break
        }
    }
    return Rate(perHour: max(0, (last.1-baseline)*3600/span), observedSeconds: span)
}

public struct TokenSummary: Decodable { public let lifetimeTokens: Double? }
public struct TokenUsageResponse: Decodable { public let summary: TokenSummary? }
public struct TokenSample: Codable { public let timestamp: Double; public let total: Double }
public struct TokenHistory: Codable {
    public private(set) var account: String?
    public private(set) var samples: [TokenSample] = []
    public init() {}
    public mutating func record(account identity: String, total: Double?, now: Double) {
        if account != identity { samples = []; account = identity }
        guard let total, total.isFinite, total >= 0 else { samples = []; return }
        samples = samples.filter { $0.timestamp >= now-historyRetentionSeconds && $0.timestamp <= now }
        if let last = samples.last {
            let gap = now-last.timestamp
            if gap < 0 || gap > 300 || total < last.total { samples = [] }
            else if gap == 0 { samples.removeLast() }
        }
        samples.append(TokenSample(timestamp: now, total: total))
    }
    public func rate(now: Double, lookback: Double = 3600) -> Rate? {
        guard let last = samples.last, now >= last.timestamp, now-last.timestamp <= 300 else { return nil }
        return observedRate(samples.map { ($0.timestamp, $0.total) }, lookback: lookback)
    }
}
