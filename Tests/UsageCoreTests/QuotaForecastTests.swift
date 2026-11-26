import XCTest
@testable import UsageCore

final class QuotaForecastTests: XCTestCase {
    func testOnTrackTightAndExhausting() {
        let now = 1_000_000.0
        let onTrack = forecastQuota(used: 20, perHour: 5, resetsAt: now + 4 * 3600, now: now)
        XCTAssertEqual(onTrack?.projectedUsedAtReset, 40)
        XCTAssertNil(onTrack?.exhaustsAt)
        XCTAssertEqual(onTrack?.outlook, .onTrack)

        let tight = forecastQuota(used: 80, perHour: 5, resetsAt: now + 2 * 3600, now: now)
        XCTAssertEqual(tight?.projectedUsedAtReset, 90)
        XCTAssertEqual(tight?.outlook, .tight)

        let exhausts = forecastQuota(used: 60, perHour: 10, resetsAt: now + 10 * 3600, now: now)
        XCTAssertEqual(exhausts?.projectedUsedAtReset, 100)
        XCTAssertEqual(exhausts?.exhaustsAt, now + 4 * 3600)
        XCTAssertEqual(exhausts?.outlook, .exhausts)
    }

    func testReachingExactlyAtResetCountsAsExhausting() {
        let now = 0.0
        let forecast = forecastQuota(used: 50, perHour: 25, resetsAt: 2 * 3600, now: now)
        XCTAssertEqual(forecast?.exhaustsAt, 2 * 3600)
    }

    func testZeroRateAndFullWindow() {
        let now = 500.0
        let idle = forecastQuota(used: 95, perHour: 0, resetsAt: now + 3600, now: now)
        XCTAssertEqual(idle?.projectedUsedAtReset, 95)
        XCTAssertNil(idle?.exhaustsAt)
        XCTAssertEqual(idle?.outlook, .tight)

        let full = forecastQuota(used: 100, perHour: 0, resetsAt: now + 3600, now: now)
        XCTAssertEqual(full?.exhaustsAt, now)
        XCTAssertEqual(full?.outlook, .exhausts)
    }

    func testInvalidInputsHaveNoForecast() {
        let now = 100.0
        XCTAssertNil(forecastQuota(used: nil, perHour: 1, resetsAt: now + 60, now: now))
        XCTAssertNil(forecastQuota(used: 101, perHour: 1, resetsAt: now + 60, now: now))
        XCTAssertNil(forecastQuota(used: 10, perHour: nil, resetsAt: now + 60, now: now))
        XCTAssertNil(forecastQuota(used: 10, perHour: -1, resetsAt: now + 60, now: now))
        XCTAssertNil(forecastQuota(used: 10, perHour: .nan, resetsAt: now + 60, now: now))
        XCTAssertNil(forecastQuota(used: 10, perHour: 1, resetsAt: nil, now: now))
        XCTAssertNil(forecastQuota(used: 10, perHour: 1, resetsAt: now, now: now))
    }

    func testForecastLabelsExistInEnglishAndChinese() {
        for key in forecastTranslations.keys {
            for code in ["en", "zh-Hant", "zh-Hans"] {
                XCTAssertNotNil(L10n.table[key]?[code], "\(key) missing \(code)")
            }
        }
    }

    func testAlertsFireOncePerResetCycle() {
        var tracker = QuotaAlertTracker()
        let exhausting = forecastQuota(used: 60, perHour: 20, resetsAt: 10_000 + 5 * 3600, now: 10_000)
        XCTAssertEqual(tracker.alerts(windowID: "codex:primary", used: 50, resetsAt: 9_000, forecast: nil), [])
        XCTAssertEqual(tracker.alerts(windowID: "codex:primary", used: 60, resetsAt: 9_000, forecast: exhausting), [.projectedExhaustion])
        XCTAssertEqual(tracker.alerts(windowID: "codex:primary", used: 70, resetsAt: 9_000, forecast: exhausting), [])
        XCTAssertEqual(tracker.alerts(windowID: "codex:primary", used: 91, resetsAt: 9_000, forecast: exhausting), [.highUsage])
        XCTAssertEqual(tracker.alerts(windowID: "codex:primary", used: 95, resetsAt: 9_000, forecast: nil), [])
        XCTAssertEqual(tracker.alerts(windowID: "codex:secondary", used: 92, resetsAt: 9_000, forecast: nil), [.highUsage])
        // A new reset time starts a new cycle.
        XCTAssertEqual(tracker.alerts(windowID: "codex:primary", used: 92, resetsAt: 20_000, forecast: nil), [.highUsage])
        // A usage drop without a new reset time also starts a new cycle.
        XCTAssertEqual(tracker.alerts(windowID: "codex:primary", used: 5, resetsAt: 20_000, forecast: nil), [])
        XCTAssertEqual(tracker.alerts(windowID: "codex:primary", used: 93, resetsAt: 20_000, forecast: nil), [.highUsage])
        XCTAssertEqual(tracker.alerts(windowID: "codex:primary", used: nil, resetsAt: 20_000, forecast: nil), [])
    }

    func testClaudeResetJitterKeepsTheAlertCycle() {
        // Claude reports e.g. 1793300400.606, then .677, then .253 for the same reset.
        var tracker = QuotaAlertTracker()
        XCTAssertEqual(tracker.alerts(windowID: "claude:seven_day:primary", used: 95, resetsAt: 1_793_300_400.606, forecast: nil), [.highUsage])
        XCTAssertEqual(tracker.alerts(windowID: "claude:seven_day:primary", used: 95, resetsAt: 1_793_300_400.677, forecast: nil), [])
        XCTAssertEqual(tracker.alerts(windowID: "claude:seven_day:primary", used: 96, resetsAt: 1_793_300_400.253, forecast: nil), [])
        XCTAssertTrue(sameReset(nil, nil))
        XCTAssertFalse(sameReset(nil, 1))
        XCTAssertFalse(sameReset(1_000, 1_000 + 3600))
    }

    func testAlertSettingDecodesFromOlderPreferences() throws {
        let old = try JSONDecoder().decode(WidgetSettings.self, from: JSONEncoder().encode(WidgetSettings()))
        XCTAssertFalse(old.quotaAlertsEnabled)
        let legacy = #"{"language":"en","intervalValue":1,"intervalUnit":"hour","rateUnit":"hour"}"#
        XCTAssertFalse(try JSONDecoder().decode(WidgetSettings.self, from: Data(legacy.utf8)).quotaAlertsEnabled)
        var enabled = WidgetSettings(); enabled.quotaAlertsEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(WidgetSettings.self, from: JSONEncoder().encode(enabled)).quotaAlertsEnabled)
    }
}

final class QuotaAlertAdviceTests: XCTestCase {
    private let now = 1_000_000.0
    private func item(_ id: String, used: Double, reset: Double, limited: Bool = false) -> WindowItem {
        WindowItem(id: id, name: id, window: QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset), limitReached: limited)
    }
    private func name(_ id: String) -> String { id == "codex" ? "Codex" : "Claude" }

    func testSuggestsOtherAgentWhenItHasRoom() {
        let items = [item("codex:5h", used: 92, reset: now + 7200), item("claude:5h", used: 38, reset: now + 7200)]
        let advice = quotaAlertAdvice(provider: "codex", items: items, now: now)
        XCTAssertEqual(advice, .switchTo(agent: "claude", headroom: 62))
        let body = L10n(.english).quotaAlertBody(kind: .highUsage, used: 92, resetsAt: now + 7200, forecast: nil, advice: advice, agentName: name, now: now)
        XCTAssertTrue(body.contains("92%"))
        XCTAssertTrue(body.contains("Claude (62% left)"))
        let zh = L10n(.zhHant).quotaAlertBody(kind: .highUsage, used: 92, resetsAt: now + 7200, forecast: nil, advice: advice, agentName: name, now: now)
        XCTAssertTrue(zh.contains("建議改用 Claude（還有 62%）"))
    }

    func testBothLowNamesEarlierReset() {
        let items = [item("codex:5h", used: 95, reset: now + 9000), item("claude:5h", used: 96, reset: now + 3600)]
        let advice = quotaAlertAdvice(provider: "codex", items: items, now: now)
        XCTAssertEqual(advice, .bothLow(earlier: "claude", resetsAt: now + 3600))
        let body = L10n(.english).quotaAlertBody(kind: .highUsage, used: 95, resetsAt: now + 9000, forecast: nil, advice: advice, agentName: name, now: now)
        XCTAssertTrue(body.contains("Both agents are low; Claude resets first"))
    }

    func testBothLowWithoutResetTimes() {
        let items = [item("codex:5h", used: 95, reset: now - 1, limited: true), item("claude:5h", used: 100, reset: now - 1, limited: true)]
        let advice = quotaAlertAdvice(provider: "codex", items: items, now: now)
        XCTAssertEqual(advice, .bothLow(earlier: nil, resetsAt: nil))
    }

    func testNoFallbackKeepsOriginalText() {
        let items = [item("codex:5h", used: 92, reset: now + 7200)]
        XCTAssertNil(quotaAlertAdvice(provider: "codex", items: items, now: now))
        XCTAssertNil(quotaAlertAdvice(provider: "deepseek", items: items, now: now))
        let plain = L10n(.english).quotaAlertBody(kind: .highUsage, used: 92, resetsAt: now + 7200, forecast: nil, advice: nil, agentName: name, now: now)
        XCTAssertFalse(plain.contains("\n"))
    }

    func testProjectedExhaustionBodyAndOncePerCycle() {
        let items = [item("codex:5h", used: 60, reset: now + 36000), item("claude:5h", used: 38, reset: now + 36000)]
        let forecast = forecastQuota(used: 60, perHour: 60, resetsAt: now + 36000, now: now)
        var tracker = QuotaAlertTracker()
        let first = tracker.alerts(windowID: "codex:5h", used: 60, resetsAt: now + 36000, forecast: forecast)
        XCTAssertEqual(first, [.projectedExhaustion])
        XCTAssertTrue(tracker.alerts(windowID: "codex:5h", used: 61, resetsAt: now + 36000, forecast: forecast).isEmpty)
        let advice = quotaAlertAdvice(provider: "codex", items: items, now: now)
        let body = L10n(.english).quotaAlertBody(kind: .projectedExhaustion, used: 60, resetsAt: now + 36000, forecast: forecast, advice: advice, agentName: name, now: now)
        XCTAssertTrue(body.contains("before reset at this pace"))
        XCTAssertNil(advice)
        XCTAssertFalse(body.contains("\n"))
    }

    func testNoBothLowWhenAlertingAgentHasRoom() {
        let items = [item("codex:5h", used: 40, reset: now + 36000), item("claude:5h", used: 95, reset: now + 36000)]
        XCTAssertNil(quotaAlertAdvice(provider: "codex", items: items, now: now))
    }

    func testAdviceShowsActualRemainingNotSoonResetHeadroom() {
        let items = [item("codex:5h", used: 92, reset: now + 7200), item("claude:5h", used: 95, reset: now + 600)] as [WindowItem]
        // Routing counts the window as replenished (resets in 10 min), but the text shows the real 5% left.
        XCTAssertEqual(quotaAlertAdvice(provider: "codex", items: items, now: now), .switchTo(agent: "claude", headroom: 5))
    }
}
