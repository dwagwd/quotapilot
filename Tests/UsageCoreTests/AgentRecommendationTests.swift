import XCTest
@testable import UsageCore

final class AgentRecommendationTests: XCTestCase {
    private func item(_ id: String, used: Double, reset: Double = 10_000, limited: Bool = false) -> WindowItem {
        WindowItem(id: id, name: id, window: QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset), limitReached: limited)
    }

    func testPrefersTheAgentWhoseTightestWindowHasMoreRoom() {
        let items = [item("codex:primary", used: 44), item("claude:five_hour:primary", used: 24), item("claude:seven_day:primary", used: 95)]
        let pick = recommendedAgent(items: items, now: 0)
        XCTAssertEqual(pick?.provider, "codex")
        XCTAssertEqual(pick?.remaining, 56)
    }

    func testIgnoresExpiredWindowsAndNeedsTwoAgents() {
        XCTAssertNil(recommendedAgent(items: [item("codex:primary", used: 10)], now: 0))
        let items = [item("codex:primary", used: 10, limited: true), item("claude:five_hour:primary", used: 99, reset: 5)]
        XCTAssertNil(recommendedAgent(items: items, now: 100), "Claude's only window already reset, so there is nothing to compare")
        XCTAssertEqual(recommendedAgent(items: items, now: 0)?.provider, "claude", "a rate-limited agent has no room")
    }
}
