import XCTest
@testable import UsageCore

final class AgentRouterTests: XCTestCase {
    private func item(_ id: String, used: Double, reset: Double = 100_000, limited: Bool = false) -> WindowItem {
        WindowItem(id: id, name: id, window: QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset), limitReached: limited)
    }
    private var current: [WindowItem] {
        [item("codex:primary", used: 32), item("claude:five_hour:primary", used: 24), item("claude:seven_day:primary", used: 92)]
    }

    func testAutoUsesTightestWindowPerAgent() {
        let decision = AgentRouter.decide(mode: .auto, items: current, now: 0)
        XCTAssertEqual(decision.agent, "codex")
        XCTAssertEqual(decision.agents.first { $0.provider == "claude" }?.headroom, 8)
        XCTAssertEqual(decision.agents.first { $0.provider == "claude" }?.limitingWindow, "claude:seven_day:primary")
    }

    func testPreferenceFallsBackWhenPreferredAgentIsLow() {
        XCTAssertEqual(AgentRouter.decide(mode: .preferClaude, items: current, now: 0).agent, "codex")
        XCTAssertEqual(AgentRouter.decide(mode: .preferClaude, items: current, now: 0).reason, "preferredLow")
        XCTAssertEqual(AgentRouter.decide(mode: .preferCodex, items: current, now: 0).reason, "preferred")
    }

    func testWindowResettingSoonCountsAsReplenished() {
        var items = current
        items[2] = item("claude:seven_day:primary", used: 92, reset: 1_000)
        let decision = AgentRouter.decide(mode: .preferClaude, items: items, now: 0)
        XCTAssertEqual(decision.agent, "claude")
        XCTAssertEqual(decision.agents.first { $0.provider == "claude" }?.headroom, 76)
    }

    func testAllLowOrRateLimited() {
        let items = [item("codex:primary", used: 10, limited: true), item("claude:five_hour:primary", used: 95)]
        let decision = AgentRouter.decide(mode: .auto, items: items, now: 0)
        XCTAssertNil(decision.agent)
        XCTAssertEqual(decision.reason, "allLow")
        XCTAssertEqual(AgentRouter.decide(mode: .auto, items: [], now: 0).reason, "noData")
    }

    func testTaskRulesWinUnlessThatAgentIsLow() {
        let rules: [TaskKind: TaskAssignee] = [.web: .codex, .review: .codex, .plan: .claude, .implement: .claude]
        let healthy = [item("codex:primary", used: 30), item("claude:five_hour:primary", used: 20), item("claude:seven_day:primary", used: 40)]
        XCTAssertEqual(AgentRouter.assign(.web, rules: rules, mode: .auto, items: healthy, now: 0).agent, "codex")
        XCTAssertEqual(AgentRouter.assign(.implement, rules: rules, mode: .auto, items: healthy, now: 0).agent, "claude")
        let claudeLow = AgentRouter.assign(.implement, rules: rules, mode: .auto, items: current, now: 0)
        XCTAssertEqual(claudeLow.agent, "codex")
        XCTAssertEqual(claudeLow.reason, "ruleLowQuota")
        XCTAssertEqual(AgentRouter.assign(.plan, rules: [:], mode: .preferClaude, items: current, now: 0).agent, "codex", "auto follows the quota router")
    }
}
