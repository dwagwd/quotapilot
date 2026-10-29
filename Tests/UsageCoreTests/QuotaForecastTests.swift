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
