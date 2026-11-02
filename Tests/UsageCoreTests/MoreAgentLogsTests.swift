import XCTest
@testable import UsageCore

final class MoreAgentLogsTests: XCTestCase {
    let geminiLines = [
        #"{"sessionId":"s1","projectHash":"h","startTime":"2026-10-19T08:00:00.000Z","kind":"main"}"#,
        #"{"id":"u1","timestamp":"2026-10-19T08:00:01.000Z","type":"user","content":[{"text":"hi"}]}"#,
        #"{"id":"g1","timestamp":"2026-10-19T08:00:11.000Z","type":"gemini","model":"gemini-4-argon","tokens":{"input":1200,"cached":200,"output":300,"thoughts":200,"tool":50,"total":1750}}"#,
        #"{"id":"g1","timestamp":"2026-10-19T08:00:11.000Z","type":"gemini","model":"gemini-4-argon","tokens":{"input":1200,"cached":200,"output":300,"thoughts":200,"tool":50,"total":1750}}"#
    ]

    func testGeminiTokensSplitCacheAndThoughts() throws {
        let event = try XCTUnwrap(AgentLogParser.geminiEvent(geminiLines[2]))
        XCTAssertEqual(event.provider, "gemini")
        XCTAssertEqual(event.usage.input, 1050)
        XCTAssertEqual(event.usage.cacheRead, 200)
        XCTAssertEqual(event.usage.output, 500)
        XCTAssertEqual(event.usage.reasoning, 200)
        XCTAssertEqual(event.dedupeKey, AgentLogParser.geminiEvent(geminiLines[3])?.dedupeKey, "a re-written message is the same call")
        XCTAssertNil(AgentLogParser.geminiEvent(geminiLines[1]))
        XCTAssertEqual(AgentLogParser.geminiModelEvent(geminiLines[2])?.model, "gemini-4-argon")
    }

    func testGeminiSpeedCountsEachMessageOnce() {
        var timer = CallTimer(provider: "gemini")
        let samples = geminiLines.flatMap { timer.feed($0) }
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].seconds, 10, accuracy: 0.01)
        XCTAssertEqual(samples[0].outputTokens, 500)
        XCTAssertEqual(samples[0].reasoningTokens, 200)
        XCTAssertEqual(samples[0].model, "gemini-4-argon")
    }

    func testGrokInferenceLines() throws {
        let line = #"{"msg":"shell.turn.inference_done","sid":"s9","ts":"2026-07-01T18:16:00.000Z","ctx":{"loop_index":2,"prompt_tokens":1000,"cached_prompt_tokens":600,"completion_tokens":150,"reasoning_tokens":90}}"#
        let event = try XCTUnwrap(AgentLogParser.grokEvent(line))
        XCTAssertEqual(event.provider, "grok")
        XCTAssertEqual(event.usage.input, 400)
        XCTAssertEqual(event.usage.cacheRead, 600)
        XCTAssertEqual(event.usage.output, 150)
        XCTAssertEqual(event.usage.reasoning, 90)
        XCTAssertNil(AgentLogParser.grokEvent(#"{"msg":"shell.turn.started","sid":"s9","ts":"2026-07-01T18:16:00.000Z"}"#))
        var timer = CallTimer(provider: "grok")
        XCTAssertTrue(timer.feed(line).isEmpty, "no start time, so no speed")
    }

    func testNewProvidersMapToSite() {
        XCTAssertEqual(ContributionReport.siteProvider("gemini"), "gemini")
        XCTAssertEqual(ContributionReport.siteProvider("grok"), "grok")
        XCTAssertNil(ContributionReport.siteProvider("antigravity"), "the site covers ChatGPT, Claude, Grok and Gemini only")
        XCTAssertNil(ContributionReport.siteProvider("cursor"))
        XCTAssertNil(ContributionReport.siteProvider("deepseek"))
    }
}
