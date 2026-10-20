import Foundation

/// Card layouts: the original detailed card, one text line per agent, or one small bar per quota window.
public enum CardStyle: String, Codable, CaseIterable { case detailed, compact, bars }

/// Optional parts of each agent line on the card.
public enum CardField: String, Codable, CaseIterable { case countdown, quotaRate, tokens, outputSpeed, model, effort, total }

/// Optional system readings for the card.
public enum SystemField: String, Codable, CaseIterable { case cpu, gpu, temperature, memory, disk }

/// Formats a system line such as `CPU 54% · GPU 8% · 64°C · RAM 78% · Disk 96%`. Missing readings are skipped.
public func systemLine(cpu: Double?, gpu: Double?, temperatureC: Double?, memory: Double?, disk: Double?,
                       fields: Set<SystemField>, fahrenheit: Bool) -> String {
    var parts: [String] = []
    func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }
    if fields.contains(.cpu), let cpu { parts.append("CPU " + pct(cpu)) }
    if fields.contains(.gpu), let gpu { parts.append("GPU " + pct(gpu)) }
    if fields.contains(.temperature), let t = temperatureC {
        parts.append(fahrenheit ? String(format: "%.0f°F", t * 9 / 5 + 32) : String(format: "%.0f°C", t))
    }
    if fields.contains(.memory), let memory { parts.append("RAM " + pct(memory)) }
    if fields.contains(.disk), let disk { parts.append("Disk " + pct(disk)) }
    return parts.joined(separator: " · ")
}

public enum RouterMode: String, Codable, CaseIterable { case auto, preferCodex, preferClaude }

public struct AgentHeadroom: Equatable {
    public let provider: String
    /// Remaining percentage of the agent's tightest window, after counting windows that reset soon as full.
    public let headroom: Double
    public let limitingWindow: String?
    public let resetsAt: Double?
}

public struct RouterDecision: Equatable {
    public let agent: String?
    public let reason: String
    public let agents: [AgentHeadroom]
}

/// Chooses which agent should take delegated work. Every window counts (5-hour and weekly), the tightest one
/// decides an agent's headroom, and a window that resets within `soonSeconds` counts as replenished.
public enum AgentRouter {
    public static let minimumHeadroom: Double = 10
    public static let soonSeconds: Double = 1800
    public static let agents = ["codex", "claude"]

    public static func headroom(items: [WindowItem], now: Double) -> [AgentHeadroom] {
        var result: [String: AgentHeadroom] = [:]
        for item in items {
            let provider = String(item.id.split(separator: ":").first ?? "")
            guard agents.contains(provider), let used = item.window.validUsedPercent else { continue }
            if let reset = item.window.resetsAt, reset <= now { continue }
            var remaining = item.limitReached ? 0 : 100 - used
            if let reset = item.window.resetsAt, reset - now <= soonSeconds { remaining = 100 }
            if let current = result[provider], current.headroom <= remaining { continue }
            result[provider] = AgentHeadroom(provider: provider, headroom: remaining, limitingWindow: item.id, resetsAt: item.window.resetsAt)
        }
        return agents.compactMap { result[$0] }
    }

    public static func decide(mode: RouterMode, items: [WindowItem], now: Double) -> RouterDecision {
        let rooms = headroom(items: items, now: now)
        func room(_ id: String) -> AgentHeadroom? { rooms.first { $0.provider == id } }
        func usable(_ id: String) -> Bool { (room(id)?.headroom ?? 0) >= minimumHeadroom }
        switch mode {
        case .preferCodex, .preferClaude:
            let first = mode == .preferCodex ? "codex" : "claude", second = first == "codex" ? "claude" : "codex"
            if usable(first) { return RouterDecision(agent: first, reason: "preferred", agents: rooms) }
            if usable(second) { return RouterDecision(agent: second, reason: "preferredLow", agents: rooms) }
            return RouterDecision(agent: nil, reason: "allLow", agents: rooms)
        case .auto:
            let candidates = rooms.filter { usable($0.provider) }
            guard let best = candidates.max(by: { $0.headroom < $1.headroom }) else {
                return RouterDecision(agent: nil, reason: rooms.isEmpty ? "noData" : "allLow", agents: rooms)
            }
            return RouterDecision(agent: best.provider, reason: candidates.count == 1 ? "onlyAvailable" : "mostHeadroom", agents: rooms)
        }
    }
}

/// Kinds of work that can be routed to a specific agent.
public enum TaskKind: String, Codable, CaseIterable { case web, review, plan, implement }

/// Per-task preference: a named agent, or `auto` to follow the quota router.
public enum TaskAssignee: String, Codable, CaseIterable { case auto, codex, claude }

extension AgentRouter {
    /// The agent for a kind of task: the user's choice when it has quota headroom, otherwise the other agent,
    /// otherwise whatever the quota router picks.
    public static func assign(_ kind: TaskKind, rules: [TaskKind: TaskAssignee], mode: RouterMode,
                              items: [WindowItem], now: Double) -> (agent: String?, reason: String) {
        let decision = decide(mode: mode, items: items, now: now)
        guard let preferred = rules[kind], preferred != .auto else { return (decision.agent, "quota") }
        let rooms = headroom(items: items, now: now)
        func usable(_ id: String) -> Bool {
            guard let room = rooms.first(where: { $0.provider == id }) else { return true }  // no quota data: trust the rule
            return room.headroom >= minimumHeadroom
        }
        if usable(preferred.rawValue) { return (preferred.rawValue, "rule") }
        let other = preferred == .codex ? "claude" : "codex"
        return usable(other) ? (other, "ruleLowQuota") : (nil, "allLow")
    }
}
