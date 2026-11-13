import XCTest
@testable import UsageCore

final class UsageDisplayCacheTests: XCTestCase {
    private func event(_ key: String, time: Double, tokens: Double) -> AgentTokenEvent {
        AgentTokenEvent(provider: "codex", timestamp: time, usage: TokenBreakdown(output: tokens), dedupeKey: key)
    }

    func testTimeAndWindowChangesExpireAggregatesWithoutNewData() {
        var ledger = AgentTokenLedger(), cache = UsageDisplayCache()
        ledger.add(event("a", time: 300, tokens: 10))
        let stats = UsageStatsStore()
        XCTAssertEqual(cache.snapshot(ledger: ledger, stats: stats, lookback: 60, now: 600).total.total, 10)
        XCTAssertEqual(cache.snapshot(ledger: ledger, stats: stats, lookback: 60, now: 659).total.total, 10)
        XCTAssertEqual(cache.snapshot(ledger: ledger, stats: stats, lookback: 60, now: 660).total.total, 0)
        XCTAssertEqual(cache.snapshot(ledger: ledger, stats: stats, lookback: 3600, now: 660).total.total, 10)
        XCTAssertEqual(cache.snapshot(ledger: ledger, stats: stats, lookback: 60, now: 600).total.total, 10, "clock reversal refreshes the cache")
    }

    func testInvalidationIncludesNewCallsAndClearedLedgers() {
        var ledger = AgentTokenLedger(), stats = UsageStatsStore(), cache = UsageDisplayCache()
        ledger.add(event("a", time: 3700, tokens: 10))
        XCTAssertEqual(cache.snapshot(ledger: ledger, stats: stats, lookback: 3600, now: 3800).total.total, 10)
        ledger.add(event("b", time: 3750, tokens: 20))
        stats.addSpeed(OutputSpeedSample(provider: "codex", timestamp: 3750, outputTokens: 200, reasoningTokens: 0, seconds: 10, key: "b"))
        cache.invalidate()
        let updated = cache.snapshot(ledger: ledger, stats: stats, lookback: 3600, now: 3801)
        XCTAssertEqual(updated.tokens["codex"]?.total, 30)
        XCTAssertEqual(updated.speeds["codex"]?.tokensPerSecond, 20)
        XCTAssertEqual(updated.displaySpeeds["codex"]?.tokensPerSecond, 20)
        cache.invalidate()
        XCTAssertEqual(cache.snapshot(ledger: AgentTokenLedger(), stats: stats, lookback: 3600, now: 3802).total.total, 0)
    }

    func testShortWindowKeepsTheDisplaySpeedFloor() {
        var stats = UsageStatsStore(), cache = UsageDisplayCache()
        stats.addSpeed(OutputSpeedSample(provider: "codex", timestamp: 3500, outputTokens: 100, reasoningTokens: 0, seconds: 10, key: "old-hour"))
        let snapshot = cache.snapshot(ledger: AgentTokenLedger(), stats: stats, lookback: 60, now: 7200)
        XCTAssertNil(snapshot.speeds["codex"])
        XCTAssertNil(snapshot.displaySpeeds["codex"], "the oldest hour has expired even with the one-hour floor")
        let earlier = cache.snapshot(ledger: AgentTokenLedger(), stats: stats, lookback: 60, now: 3900)
        XCTAssertNil(earlier.speeds["codex"])
        XCTAssertEqual(earlier.displaySpeeds["codex"]?.tokensPerSecond, 10)
    }
}
