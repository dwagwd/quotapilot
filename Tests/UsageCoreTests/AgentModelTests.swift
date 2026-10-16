import XCTest
@testable import UsageCore

final class AgentModelTests: XCTestCase {
    func testParsesRequestedModelRerouteAndClaudeServedModel() throws {
        let turn = #"{"timestamp":"2026-10-16T03:44:28.014Z","type":"turn_context","payload":{"model":"gpt-6.1-sol","effort":"max","cwd":"/w"}}"#
        let requested = try XCTUnwrap(AgentLogParser.codexModelEvent(turn))
        XCTAssertEqual(requested.kind, .requested)
        XCTAssertEqual(requested.model, "gpt-6.1-sol")
        XCTAssertEqual(requested.effort, "max")

        let reroute = #"{"timestamp":"2026-10-16T03:45:00Z","type":"event_msg","payload":{"type":"model_reroute","from_model":"gpt-6.1-sol","to_model":"gpt-6.1-mini","reason":"high_risk_cyber_activity"}}"#
        let event = try XCTUnwrap(AgentLogParser.codexModelEvent(reroute))
        XCTAssertEqual(event.kind, .rerouted)
        XCTAssertEqual(event.fromModel, "gpt-6.1-sol")
        XCTAssertEqual(event.model, "gpt-6.1-mini")
        XCTAssertEqual(event.reason, "high_risk_cyber_activity")
        XCTAssertNil(AgentLogParser.codexModelEvent(#"{"type":"response_item","payload":{"type":"message","text":"turn_context"}}"#))

        let claude = #"{"type":"assistant","timestamp":"2026-10-16T03:46:00Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1}}}"#
        XCTAssertEqual(AgentLogParser.claudeModelEvent(claude)?.model, "claude-opus-5-5")
        XCTAssertEqual(AgentLogParser.claudeModelEvent(claude)?.kind, .served)
    }

    func testTrackerKeepsLatestModelAndDeduplicatesReroutes() {
        var tracker = AgentModelTracker()
        tracker.observe(AgentModelEvent(provider: "codex", timestamp: 10, kind: .requested, model: "a", fromModel: nil, effort: "high", reason: nil))
        tracker.observe(AgentModelEvent(provider: "codex", timestamp: 5, kind: .requested, model: "old", fromModel: nil, effort: nil, reason: nil))
        XCTAssertEqual(tracker.current["codex"]?.model, "a")
        XCTAssertEqual(tracker.current["codex"]?.effort, "high")
        let reroute = AgentModelEvent(provider: "codex", timestamp: 20, kind: .rerouted, model: "b", fromModel: "a", effort: nil, reason: "x")
        XCTAssertTrue(tracker.observe(reroute))
        XCTAssertFalse(tracker.observe(reroute))
        XCTAssertEqual(tracker.recentReroutes(provider: "codex", since: 15).count, 1)
        XCTAssertTrue(tracker.recentReroutes(provider: "codex", since: 25).isEmpty)
    }
}
