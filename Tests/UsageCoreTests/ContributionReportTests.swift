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
