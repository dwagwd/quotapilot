import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import UsageCore
import UsageTransport

// quotapilot — cross-platform command-line companion to the QuotaPilot menu bar app.
// Reads Codex quota (Codex app server), Claude plan usage (Claude Code login), local agent token logs,
// and answers "which agent should take this task" for skills and scripts.

let version = "0.6.3"
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
    return WidgetSettings()
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
func fetchCodexWindows(timeout: Double = 30) -> (windows: [WindowItem], error: String?) {
    let client = UsageClient(requestTimeout: 20)
    var result: [WindowItem]?
    var failure: String?
    client.onResult = { response, _ in result = response.windows() }
    client.onFailure = { code in failure = code }
    if ProcessInfo.processInfo.environment["QUOTAPILOT_DEBUG"] != nil {
        client.onDiagnostics = { d in FileHandle.standardError.write(Data("diag connected=\(d.connected) inflight=\(d.requestInFlight) fail=\(d.lastFailureCode ?? "-") exe=\(client.executable ?? "-")\n".utf8)) }
    }
    client.refresh()
    let deadline = Date().addingTimeInterval(timeout)
    while result == nil && Date() < deadline {
        if failure == "clientMissing" { break }
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    client.stop()
    if let result { return (result, nil) }
    return ([], failure ?? "timeout")
}

func readClaudeCredentials() -> Data? {
    #if os(macOS)
    // The same keychain item Claude Code uses; `security` prints it for the current user.
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    if (try? process.run()) != nil {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0, !data.isEmpty { return data }
    }
    #endif
    return try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json"))
}

func fetchClaudeWindows() -> (windows: [WindowItem], error: String?) {
    guard let data = readClaudeCredentials(), let login = ClaudePlanUsage.credentials(from: data) else { return ([], "claudeLoginMissing") }
    if let expires = login.expiresAt, expires <= Date().timeIntervalSince1970 { return ([], "claudeLoginExpired") }
    var request = URLRequest(url: ClaudePlanUsage.endpoint, timeoutInterval: 20)
    request.setValue("Bearer " + login.token, forHTTPHeaderField: "Authorization")
    request.setValue(ClaudePlanUsage.betaHeader, forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let done = DispatchSemaphore(value: 0)
    var body: Data?, status = 0
    URLSession.shared.dataTask(with: request) { data, response, _ in
        body = data; status = (response as? HTTPURLResponse)?.statusCode ?? 0; done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 25)
    guard (200..<300).contains(status), let body,
          let snapshot = ClaudePlanUsage.snapshot(from: body, plan: login.plan, account: ClaudePlanUsage.localAccountID(home: FileManager.default.homeDirectoryForCurrentUser), now: Date().timeIntervalSince1970) else {
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

func tokenSummary(hours: Double) -> [String: TokenBreakdown] {
    let now = Date().timeIntervalSince1970
    let scanner = AgentLogScanner(sources: AgentLogScanner.defaultSources(home: FileManager.default.homeDirectoryForCurrentUser))
    var ledger = AgentTokenLedger()
    for event in scanner.scan(windowStart: now - hours * 3600, now: now) { ledger.add(event) }
    for model in scanner.lastModelEvents { modelTracker.observe(model) }
    speedSamples = scanner.lastSpeedSamples.filter { $0.timestamp >= now - hours * 3600 }
    return ledger.summary(since: now - hours * 3600, now: now)
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
    var errors: [String: String] = [:]
    let codex = fetchCodexWindows()
    if let error = codex.error { errors["codex"] = error }
    let claude: (windows: [WindowItem], error: String?) = AgentDetectionCLI.claudeInstalled ? fetchClaudeWindows() : ([], nil)
    if let error = claude.error { errors["claude"] = error }
    return Snapshot(windows: codex.windows + claude.windows, errors: errors,
                    tokens: includeTokens ? tokenSummary(hours: tokenHours) : [:], tokenHours: tokenHours,
                    settings: loadSettings(), now: Date().timeIntervalSince1970)
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
            ["id": item.id, "name": item.name, "planType": item.planType ?? NSNull(), "usedPercent": item.window.validUsedPercent ?? NSNull(),
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
    for (agent, error) in snapshot.errors.sorted(by: { $0.key < $1.key }) { lines.append(providerName(agent) + ": " + error) }
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
    let now = Date().timeIntervalSince1970
    var errors: [String: String] = [:]
    let codex = fetchCodexWindows()
    if let error = codex.error { errors["codex"] = error }
    let claude: (windows: [WindowItem], error: String?) = AgentDetectionCLI.claudeInstalled ? fetchClaudeWindows() : ([], nil)
    if let error = claude.error { errors["claude"] = error }
    let windows = (codex.windows + claude.windows).filter { ContributionReport.sharedProvider(windowID: $0.id) != nil }
    let starts = windows.compactMap { item -> Double? in
        guard let reset = item.window.resetsAt, let mins = item.window.windowDurationMins else { return nil }
        return reset - Double(mins) * 60
    }
    let earliest = min(now - hours * 3600, starts.min() ?? now)
    let scanner = AgentLogScanner(sources: AgentLogScanner.defaultSources(home: FileManager.default.homeDirectoryForCurrentUser))
    let events = scanner.scan(windowStart: max(earliest, now - 8 * 86400), now: now)
    for model in scanner.lastModelEvents { modelTracker.observe(model) }
    let speed = scanner.lastSpeedSamples.filter { $0.timestamp >= now - hours * 3600 }
    let uses = ContributionReport.windowUses(items: windows, tokensSince: { provider, start in
        events.filter { $0.provider == provider && $0.timestamp >= start }.reduce(into: TokenBreakdown()) { $0.add($1.usage) }
    }, model: { modelTracker.current[$0]?.model })
    return (ContributionReport.build(speed: speed, windows: uses, now: now, include: shareKinds()), errors)
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

// MARK: Commands

let usage = """
quotapilot \(version) — plan quota, token usage and agent routing for Codex and Claude Code

USAGE
  quotapilot [status] [--json] [--hours N]   Quota, tokens (default last 24 h) and routing
  quotapilot watch [--interval SECONDS]      Refresh status in the terminal (default 60 s)
  quotapilot route <web|review|plan|implement> [--json]
                                             Print the agent for a kind of task (exit 3 if none)
  quotapilot stats [--hours N] [--json]      Token totals by agent and purpose from local logs
  quotapilot config [show]                   Show router mode and task rules
  quotapilot config mode <auto|preferCodex|preferClaude>
  quotapilot config rule <web|review|plan|implement> <auto|codex|claude>
  quotapilot share [--hours N] [--only speed,promptCache,quota,limitEvents] [--json] [--yes] | --forget
                                             Preview anonymous speed and quota numbers and, only if
                                             you confirm, send them anonymously to AI Quota Watch.
                                             `share --yes` in cron shares daily.
                                             `share --forget` deletes everything this computer sent.
  quotapilot version

On macOS the router mode and rules come from the QuotaPilot app when it is installed;
elsewhere they are stored in \(configURL.path).
"""

let command: String = {
    if arguments.contains("--help") { return "help" }
    if arguments.contains("--version") { return "version" }
    // Skip option values such as `--hours 6` or `--interval 30`.
    let valueIndices = Set(["--hours", "--interval"].compactMap { arguments.firstIndex(of: $0).map { $0 + 1 } })
    return arguments.indices.first { !valueIndices.contains($0) && (!arguments[$0].hasPrefix("-") || arguments[$0] == "-h") }
        .map { arguments[$0] } ?? "status"
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
case "status":
    let snapshot = collect(tokenHours: hours)
    if wantsJSON { printJSON(statusObject(snapshot)) } else { print(renderText(snapshot)) }
case "watch":
    let interval = max(15, Double(option("--interval") ?? "") ?? 60)
    while true {
        let snapshot = collect(tokenHours: hours)
        print("\u{1B}[2J\u{1B}[H" + renderText(snapshot) + "\n\nRefreshing every \(Int(interval)) s · Ctrl-C to stop")
        Thread.sleep(forTimeInterval: interval)
    }
case "route":
    guard let raw = arguments.dropFirst(arguments.firstIndex(of: "route").map { $0 + 1 } ?? 1).first(where: { !$0.hasPrefix("--") }),
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
    if wantsJSON {
        let speed = Dictionary(grouping: speedSamples, by: \.provider).compactMapValues { samples -> [String: Any]? in
            guard let s = OutputSpeedSummary(samples) else { return nil }
            return ["tokensPerSecond": s.tokensPerSecond, "medianTokensPerSecond": s.medianTokensPerSecond, "calls": s.calls, "outputTokens": s.outputTokens, "seconds": s.seconds]
        }
        printJSON(["hours": hours, "total": breakdownJSON(total), "providers": summary.mapValues(breakdownJSON), "outputSpeed": speed])
    } else {
        print("Tokens in the last \(hoursLabel(hours)): \(l.compact(total.total)) · ≈\(l.compact(total.total / hours))/h · ≈\(l.compact(total.total / hours / 3600))/s")
        print("  " + breakdownText(total))
        for (provider, usage) in summary.sorted(by: { $0.value.total > $1.value.total }) {
            print(providerName(provider).padding(toLength: 9, withPad: " ", startingAt: 0) + l.compact(usage.total) + "  " + breakdownText(usage))
        }
        for line in speedText() { print("Output speed  " + line) }
        print("  Output speed = output tokens (incl. reasoning) ÷ model-call time. The time includes prefill and time to first token, so it is a lower bound on decode (TG) tok/s.")
    }
case "share":
    if arguments.contains("--forget") {
        // Right to erasure: the collector deletes everything this computer's anonymous id sent.
        switch ShareSubmitter.forgetAnonymous() {
        case .success(let n): print("Deleted \(n) stored report batches from the AI Quota Watch collector. Public stats drop them at the next rebuild (within 6 hours)."); exit(0)
        case .failure(let error): fail("Could not delete: " + error.localizedDescription)
        }
    }
    let (reports, errors) = shareReports(hours: hours)
    let data = (try? JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    let json = String(decoding: data, as: UTF8.self)
    if wantsJSON { print(json); exit(0) }  // preview only, never sends
    for (agent, error) in errors.sorted(by: { $0.key < $1.key }) { print(providerName(agent) + ": " + error) }
    guard !reports.isEmpty else {
        print("Nothing to share yet. Speed needs 3 calls per model and effort in the last \(hoursLabel(hours)); quota needs at least 1% of a 5-hour or weekly window used.")
        exit(0)
    }
    print("QuotaPilot can share these anonymous numbers with AI Quota Watch:\n")
    for report in reports { print("  " + describeReport(report)) }
    print("\nExactly what would be sent:\n\(json)\n")
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
    case .failure(let error): fail("Could not share: " + error.localizedDescription)
    }
case "config":
    var settings = loadSettings()
    let rest = Array(arguments.drop { $0 != "config" }.dropFirst())
    switch rest.first ?? "show" {
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
        print("mode: " + (settings.routerMode ?? .auto).rawValue)
        for kind in TaskKind.allCases { print("rule \(kind.rawValue): " + (settings.taskRouting[kind] ?? .auto).rawValue) }
        #if os(macOS)
        print("(macOS: the QuotaPilot app's settings take precedence when it is installed)")
        #endif
    }
default:
    fail("Unknown command \(command)\n\n" + usage, code: 2)
}
