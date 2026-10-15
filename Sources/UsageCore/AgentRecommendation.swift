import Foundation

/// Picks the agent with the most quota headroom. An agent's headroom is its tightest window
/// (lowest remaining percentage), so a nearly exhausted weekly limit outweighs a fresh 5-hour one.
public func recommendedAgent(items: [WindowItem], now: Double) -> (provider: String, remaining: Double)? {
    var headroom: [String: Double] = [:]
    for item in items {
        guard let used = item.window.validUsedPercent, item.window.resetsAt.map({ $0 > now }) ?? true else { continue }
        let provider = String(item.id.split(separator: ":").first ?? "")
        guard !provider.isEmpty else { continue }
        let remaining = item.limitReached ? 0 : 100 - used
        headroom[provider] = min(headroom[provider] ?? 100, remaining)
    }
    guard headroom.count >= 2, let best = headroom.max(by: { $0.value < $1.value }) else { return nil }
    return (best.key, best.value)
}
