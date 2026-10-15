import Foundation

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
