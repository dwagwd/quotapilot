import XCTest
@testable import UsageCore

final class UsageStatsStoreTests: XCTestCase {
    private func event(_ key: String, _ t: Double, _ provider: String = "codex", tokens: Double = 100) -> AgentTokenEvent {
        AgentTokenEvent(provider: provider, timestamp: t, usage: TokenBreakdown(input: tokens), dedupeKey: key)
    }

    func testTokenTotalsSeriesAndDeduplication() {
        var store = UsageStatsStore()
        XCTAssertTrue(store.add(event("a", 3_600)))
        XCTAssertFalse(store.add(event("a", 3_600)))
        store.add(event("b", 3_700, "claude", tokens: 50))
        store.add(event("c", 7_300))
        XCTAssertEqual(store.tokenTotals(since: 0, now: 10_000)["codex"]?.total, 200)
        let hourly = store.tokenSeries(since: 3_600, now: 10_000, bucket: 3600).filter { $0.provider == "codex" }
        XCTAssertEqual(hourly.map(\.tokens), [100, 100])
        let daily = store.tokenSeries(since: 0, now: 10_000, bucket: 86400)
        XCTAssertEqual(daily.first { $0.provider == "claude" }?.tokens, 50)
    }

    func testPruneStopsAcceptingOldEventsAfterRestart() throws {
        var store = UsageStatsStore()
        store.add(event("x", 100_000))
        store.prune(now: 100_000 + 7 * 3600)
        XCTAssertTrue(store.add(event("late", 100_010)), "before the backfill finishes, old events are still accepted")
        store.finishBackfill(at: 100_100)
        store.prune(now: 100_100)
        var restored = try JSONDecoder().decode(UsageStatsStore.self, from: JSONEncoder().encode(store))
        XCTAssertFalse(restored.add(event("x", 100_000)), "key survives the restart")
        restored.prune(now: 100_000 + 7 * 3600)
        XCTAssertFalse(restored.add(event("old", 100_050)), "older than six hours is treated as already counted")
        XCTAssertTrue(restored.add(event("new", 100_000 + 7 * 3600 + 1)))
        XCTAssertEqual(restored.tokenTotals(since: 0, now: 200_000)["codex"]?.total, 300)
    }

    func testQuotaSamplingAndConsumptionAcrossReset() {
        var store = UsageStatsStore()
        store.recordQuota(windowID: "w", title: "Codex", used: 10, resetsAt: 50_000, now: 0)
        store.recordQuota(windowID: "w", title: "Codex", used: 10, resetsAt: 50_000, now: 60)  // throttled
        store.recordQuota(windowID: "w", title: "Codex", used: 20, resetsAt: 50_000, now: 3_600)
        store.recordQuota(windowID: "w", title: "Codex", used: 30, resetsAt: 50_000, now: 7_200)
        store.recordQuota(windowID: "w", title: "Codex", used: 5, resetsAt: 90_000, now: 10_800)   // reset
        XCTAssertEqual(store.quotaSeries(windowID: "w", since: 0).count, 4)
        let rate = store.quotaConsumptionPerHour(windowID: "w", since: 0)
        XCTAssertEqual(rate?.consumed, 25)
        XCTAssertEqual(rate?.hours ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(rate?.perHour ?? 0, 25.0 / 3, accuracy: 0.001)
        store.recordQuota(windowID: "w", title: "Codex", used: 6, resetsAt: 90_000, now: 10_800 + 8 * 3600)
        XCTAssertEqual(store.quotaConsumptionPerHour(windowID: "w", since: 0)?.hours ?? 0, 3, accuracy: 0.001, "long gaps are not observed time")
        store.prune(now: 10_800 + 36 * 86400)
        XCTAssertTrue(store.quotaWindowIDs.isEmpty)
    }

    func testBackfillProgressSurvivesRestartAndClearsWhenDone() throws {
        var store = UsageStatsStore()
        store.markBackfilled(file: "/a.jsonl")
        let restored = try JSONDecoder().decode(UsageStatsStore.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(restored.backfilledFiles, ["/a.jsonl"])
        store.finishBackfill(at: 1)
        XCTAssertNil(store.backfilledFiles)
    }
}
