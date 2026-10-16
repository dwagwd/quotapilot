import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import UsageCore
import UsageTransport

// quotapilot — cross-platform command-line companion to the QuotaPilot menu bar app.
// Reads Codex quota (Codex app server), Claude plan usage (Claude Code login), local agent token logs,
// and answers "which agent should take this task" for skills and scripts.

let version = "0.5.0-dev"
let arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
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
          let snapshot = ClaudePlanUsage.snapshot(from: body, plan: login.plan, now: Date().timeIntervalSince1970) else {
        return ([], status == 401 ? "claudeLoginExpired" : "claudePlanUnavailable")
    }
    return (snapshot.limits.windows(), nil)
}

func tokenSummary(hours: Double) -> [String: TokenBreakdown] {
    let now = Date().timeIntervalSince1970
    let scanner = AgentLogScanner(sources: AgentLogScanner.defaultSources(home: FileManager.default.homeDirectoryForCurrentUser))
    var ledger = AgentTokenLedger()
    for event in scanner.scan(windowStart: now - hours * 3600, now: now) { ledger.add(event) }
    return ledger.summary(since: now - hours * 3600, now: now)
}

// MARK: Formatting

let l = L10n(.english)
func providerName(_ id: String) -> String {
    ["codex": "Codex", "claude": "Claude", "deepseek": "DeepSeek", "kimi": "Kimi", "glm": "GLM", "qwen": "Qwen"][id] ?? id
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
        "router": routerObject(snapshot)
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
        let window = snapshot.tokenHours.truncatingRemainder(dividingBy: 24) == 0 ? "\(Int(snapshot.tokenHours / 24))d" : "\(Int(snapshot.tokenHours))h"
        lines.append("Tokens (\(window)): " + l.compact(total.total) + " · ≈" + l.compact(total.total / snapshot.tokenHours) + "/h · "
                     + snapshot.tokens.sorted { $0.value.total > $1.value.total }.map { providerName($0.key) + " " + l.compact($0.value.total) }.joined(separator: " · "))
        lines.append("  " + breakdownText(total))
    }
    let mode = snapshot.settings.routerMode ?? .auto
    lines.append("Route (\(mode.rawValue)): " + TaskKind.allCases.map { kind in
        let pick = AgentRouter.assign(kind, rules: snapshot.settings.taskRouting, mode: mode, items: snapshot.windows, now: snapshot.now)
        return kind.rawValue + "→" + (pick.agent ?? "none") + (pick.reason == "ruleLowQuota" ? "*" : "")
    }.joined(separator: "  ") + "   (* quota fallback)")
    return lines.joined(separator: "\n")
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
  quotapilot version

On macOS the router mode and rules come from the QuotaPilot app when it is installed;
elsewhere they are stored in \(configURL.path).
"""

let command = arguments.first(where: { !$0.hasPrefix("--") && Double($0) == nil }) ?? "status"
let hours = Double(option("--hours") ?? "") ?? 24

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
        printJSON(["hours": hours, "total": breakdownJSON(total), "providers": summary.mapValues(breakdownJSON)])
    } else {
        print("Tokens in the last \(Int(hours)) h: \(l.compact(total.total)) · ≈\(l.compact(total.total / hours))/h · ≈\(l.compact(total.total / hours / 3600))/s")
        print("  " + breakdownText(total))
        for (provider, usage) in summary.sorted(by: { $0.value.total > $1.value.total }) {
            print(providerName(provider).padding(toLength: 9, withPad: " ", startingAt: 0) + l.compact(usage.total) + "  " + breakdownText(usage))
        }
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
