import XCTest
@testable import UsageCore

final class OutputSpeedTests: XCTestCase {
    func testCodexPairsToolOutputWithTheNextUsageRecord() {
        var timer = CallTimer(provider: "codex")
        let lines = [
            #"{"timestamp":"2026-10-19T07:26:26.249Z","type":"response_item","payload":{"type":"custom_tool_call_output","output":"x"}}"#,
            #"{"timestamp":"2026-10-19T07:26:31.709Z","type":"response_item","payload":{"type":"reasoning"}}"#,
            #"{"timestamp":"2026-10-19T07:26:46.249Z","type":"token_usage_record","payload":{"response_id":"resp_1","usage":{"input_tokens":1000,"output_tokens":800,"reasoning_output_tokens":600}}}"#,
            #"{"timestamp":"2026-10-19T07:26:50.000Z","type":"token_usage_record","payload":{"response_id":"resp_2","usage":{"output_tokens":5}}}"#
        ]
        let samples = lines.flatMap { timer.feed($0) }
        XCTAssertEqual(samples.count, 1, "a record without a preceding request start is skipped")
        XCTAssertEqual(samples[0].seconds, 20, accuracy: 0.01)
        XCTAssertEqual(samples[0].tokensPerSecond, 40, accuracy: 0.01)
        XCTAssertEqual(samples[0].reasoningTokens, 600)
        XCTAssertEqual(samples[0].key, "codex|resp_1")
    }

    func testClaudeUsesTheLastBlockOfEachMessage() {
        var timer = CallTimer(provider: "claude")
        let lines = [
            #"{"type":"user","timestamp":"2026-10-19T08:05:00.000Z","message":{"role":"user"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-19T08:05:05.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"output_tokens":1037}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-19T08:05:10.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"output_tokens":1037}}}"#,
            #"{"type":"user","timestamp":"2026-10-19T08:05:11.000Z","message":{"content":[{"type":"tool_result"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-19T08:05:15.000Z","message":{"id":"m2","model":"deepseek-chat","usage":{"output_tokens":200}}}"#
        ]
        var samples = lines.flatMap { timer.feed($0) }
        XCTAssertEqual(samples.map(\.key), ["claude|m1"])
        XCTAssertEqual(samples[0].seconds, 10, accuracy: 0.01)
        samples = timer.flush()
        XCTAssertEqual(samples.first?.provider, "deepseek")
        XCTAssertEqual(samples.first?.tokensPerSecond ?? 0, 50, accuracy: 0.01)
    }

    func testSummaryUsesTotalsAndMedian() throws {
        let samples = [10.0, 20, 60].enumerated().map { i, speed in
            OutputSpeedSample(provider: "codex", timestamp: Double(i), outputTokens: speed * 10, reasoningTokens: 0, seconds: 10, key: "\(i)")
        }
        let summary = try XCTUnwrap(OutputSpeedSummary(samples))
        XCTAssertEqual(summary.tokensPerSecond, 30, accuracy: 0.001)
        XCTAssertEqual(summary.medianTokensPerSecond, 20)
        XCTAssertNil(OutputSpeedSummary([]))
    }
}
