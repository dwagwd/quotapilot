import XCTest
@testable import UsageCore

final class ContributionReportTests: XCTestCase {
    func testModelIDsMatchTheSite() {
        XCTAssertEqual(ContributionReport.siteModelID("gpt-6.1-sol"), "gpt-6-1-sol")
        XCTAssertEqual(ContributionReport.siteModelID("claude-opus-5-5-20261001[1m]"), "claude-opus-5-5")
        XCTAssertEqual(ContributionReport.siteModelID("Claude-Sonnet-5-5"), "claude-sonnet-5-5")
        XCTAssertNil(ContributionReport.siteModelID("../home/secret"))
        XCTAssertNil(ContributionReport.siteModelID(nil))
    }

    func testSpeedNeedsThreeCallsAndCarriesNoKeys() {
        let samples = (0..<3).map { OutputSpeedSample(provider: "claude", timestamp: Double($0), outputTokens: 500, reasoningTokens: 0, seconds: 10, key: "claude|msg_\($0)", model: "claude-opus-5-5") }
        let few = Array(samples.prefix(2))
        XCTAssertTrue(ContributionReport.build(speed: few, windows: [], now: 0).isEmpty)
        let reports = ContributionReport.build(speed: samples, windows: [], now: 7_300)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0]["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(reports[0]["outputTokens"] as? Double, 1500)
        XCTAssertEqual(reports[0]["seconds"] as? Double, 30)
        XCTAssertEqual(reports[0]["date"] as? String, "1970-01-01T02:00:00Z")
        let text = String(describing: reports)
        XCTAssertFalse(text.contains("msg_"))
    }

    func testSpeedSplitsByEffortAndKeepsReasoning() {
        func sample(_ i: Int, _ effort: String?) -> OutputSpeedSample {
            OutputSpeedSample(provider: "codex", timestamp: Double(i), outputTokens: 1000, reasoningTokens: 600, seconds: 20, key: "\(i)", model: "gpt-6.1-sol", effort: effort)
        }
        let samples = (0..<3).map { sample($0, "high") } + (3..<6).map { sample($0, "xhigh") } + (6..<9).map { sample($0, "Some private label") }
        let reports = ContributionReport.build(speed: samples, windows: [], now: 0)
        XCTAssertEqual(reports.compactMap { $0["effort"] as? String }.sorted(), ["high", "xhigh"])
        XCTAssertEqual(reports.count, 3) // the unknown label is reported without an effort
        XCTAssertEqual(reports.first { $0["effort"] as? String == "high" }?["reasoningTokens"] as? Double, 1800)
    }

    func testSpeedReportsCarryPromptAndCacheTotalsOnly() {
        let samples = (0..<3).map { i -> OutputSpeedSample in
            var s = OutputSpeedSample(provider: "claude", timestamp: Double(i), outputTokens: 500, reasoningTokens: 0, seconds: 10, key: "claude|m\(i)", model: "claude-opus-5-5")
            s.inputTokens = 10; s.cacheReadTokens = 40000; s.cacheWriteTokens = 1000
            return s
        }
        let r = ContributionReport.build(speed: samples, windows: [], now: 0)[0]
        XCTAssertEqual(r["inputTokens"] as? Double, 30)
        XCTAssertEqual(r["cacheReadTokens"] as? Double, 120000)
        XCTAssertEqual(r["cacheWriteTokens"] as? Double, 3000)
        let none = (0..<3).map { OutputSpeedSample(provider: "codex", timestamp: Double($0), outputTokens: 500, reasoningTokens: 0, seconds: 10, key: "\($0)", model: "gpt-6.1-sol") }
        XCTAssertNil(ContributionReport.build(speed: none, windows: [], now: 0)[0]["inputTokens"], "no prompt data, no fields")
    }

    func testQuotaReportSkipsCacheReadsAndUnknownWindows() {
        let use = ContributionReport.WindowUse(provider: "codex", plan: "pro", windowMinutes: 300, usedPercent: 12.34, limitReached: false,
                                               tokensSinceStart: TokenBreakdown(input: 100_000, cacheRead: 9_000_000, cacheWrite: 0, output: 20_000), model: "gpt-6.1-sol")
        var odd = use; odd.windowMinutes = 60
        let reports = ContributionReport.build(speed: [], windows: [use, odd], now: 0)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0]["provider"] as? String, "chatgpt")
        XCTAssertEqual(reports[0]["plan"] as? String, "Pro")
        XCTAssertEqual(reports[0]["tokensUsed"] as? Double, 120_000)
        XCTAssertEqual(reports[0]["percentUsed"] as? Double, 12.3)
        XCTAssertEqual(reports[0]["model"] as? String, "gpt-6-1-sol")
    }

    func testClaudeCodeLogsStayClaudeCodeAndReportsAreCapped() {
        let viaClaude = (0..<3).map { OutputSpeedSample(provider: "gemini", timestamp: Double($0), outputTokens: 100, reasoningTokens: 0, seconds: 2, key: "claude|m\($0)", model: "gemini-4-argon") }
        XCTAssertEqual(ContributionReport.build(speed: viaClaude, windows: [], now: 0).first?["client"] as? String, "Claude Code")
        let many = (0..<40).flatMap { m in (0..<3).map { OutputSpeedSample(provider: "codex", timestamp: Double($0), outputTokens: 100, reasoningTokens: 0, seconds: 2, key: "codex|\(m)-\($0)", model: "model-\(m)") } }
        XCTAssertEqual(ContributionReport.build(speed: many, windows: [], now: 0).count, ContributionReport.maximumReports)
    }

    func testLimitReachedBecomesAnEvent() {
        let use = ContributionReport.WindowUse(provider: "claude", plan: "max_5x", windowMinutes: 10080, usedPercent: 100, limitReached: true,
                                               tokensSinceStart: TokenBreakdown(), model: nil)
        let reports = ContributionReport.build(speed: [], windows: [use], now: 0)
        var weekly = use; weekly.windowMinutes = 300
        XCTAssertEqual(ContributionReport.build(speed: [], windows: [use, weekly], now: 0).filter { $0["type"] as? String == "event" }.count, 1)
        XCTAssertEqual(reports.map { $0["type"] as? String }, ["event"])
        XCTAssertEqual(reports[0]["plan"] as? String, "Max 5x")
    }
}
