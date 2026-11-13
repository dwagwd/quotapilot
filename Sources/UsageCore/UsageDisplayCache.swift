import Foundation

/// Shared aggregates for the card. Source buckets change at whole-minute boundaries because
/// observation windows are whole minutes. Countdown text still updates every second.
public struct UsageDisplaySnapshot {
    public let tokens: [String: TokenBreakdown]
    public let total: TokenBreakdown
    public let speeds: [String: (tokensPerSecond: Double, outputTokens: Double, seconds: Double)]
    public let displaySpeeds: [String: (tokensPerSecond: Double, outputTokens: Double, seconds: Double)]
}

public struct UsageDisplayCache {
    private var minute: Double?
    private var lookback: Double?
    private var value: UsageDisplaySnapshot?
    public init() {}

    /// Call after changing the ledger or statistics. Time/settings changes are detected automatically.
    public mutating func invalidate() { value = nil }

    public mutating func snapshot(ledger: AgentTokenLedger, stats: UsageStatsStore,
                                  lookback: Double, now: Double) -> UsageDisplaySnapshot {
        let minute = floor(now / 60)
        if self.minute == minute, self.lookback == lookback, let value { return value }
        let tokens = ledger.summary(since: now - lookback, now: now)
        let speeds = stats.outputSpeed(since: now - lookback, now: now)
        let snapshot = UsageDisplaySnapshot(tokens: tokens,
            total: tokens.values.reduce(into: TokenBreakdown()) { $0.add($1) },
            speeds: speeds,
            displaySpeeds: lookback >= 3600 ? speeds : stats.outputSpeed(since: now - 3600, now: now))
        self.minute = minute; self.lookback = lookback; value = snapshot
        return snapshot
    }
}
