import XCTest
@testable import UsageCore

final class SettingsAndTokensTests: XCTestCase {
    func testIntervalBoundsAndUnitConversion() {
        var settings = WidgetSettings()
        XCTAssertEqual(settings.lookback, 3600)
        settings.intervalUnit = .minute; settings.intervalValue = 1
        XCTAssertTrue(settings.isValid)
        settings.intervalValue = 0; XCTAssertFalse(settings.isValid)
        settings.intervalUnit = .day; settings.intervalValue = 30; XCTAssertTrue(settings.isValid)
        settings.intervalValue = 31; XCTAssertFalse(settings.isValid)
        settings.intervalValue = -1; XCTAssertFalse(settings.isValid)
        let rate = Rate(perHour: 120, observedSeconds: 3600)
        XCTAssertEqual(rate.value(per: .minute), 2)
        XCTAssertEqual(rate.value(per: .day), 2880)
    }
    func testSelectableLookbackUsesDifferentObservedPeriods() {
        var history = History()
        for minute in 0...120 {
            let used = minute <= 60 ? 20+Double(minute)/12 : 25+Double(minute-60)/6
            let item = WindowItem(id: "quota", name: "Codex", window: QuotaWindow(usedPercent: used, windowDurationMins: 10080, resetsAt: 999999))
            history.record(account: "A", items: [item], now: Double(minute*60))
        }
        XCTAssertEqual(history.rate(for: "quota", now: 7200, lookback: 1800)!.perHour, 10, accuracy: 0.001)
        XCTAssertEqual(history.rate(for: "quota", now: 7200, lookback: 7200)!.perHour, 7.5, accuracy: 0.001)
        XCTAssertNil(history.rate(for: "quota", now: 7200, lookback: 0))
    }
    func testRateSurvivesSubSecondResetJitter() {
        var history = History()
        for minute in 0...30 {
            let reset = 999_999 + Double(minute % 7) / 10
            let item = WindowItem(id: "claude:five_hour:primary", name: "Claude", window: QuotaWindow(usedPercent: 10 + Double(minute) / 6, windowDurationMins: 300, resetsAt: reset))
            history.record(account: "A", items: [item], now: Double(minute * 60))
        }
        XCTAssertEqual(history.rate(for: "claude:five_hour:primary", now: 1800, lookback: 3600)!.perHour, 10, accuracy: 0.001)
    }
    func testOneMinuteWarmupAndTokenRateAreIndependentOfQuota() {
        var tokens = TokenHistory()
        tokens.record(account: "A", total: 10000, now: 0)
        XCTAssertNil(tokens.rate(now: 0, lookback: 60))
        tokens.record(account: "A", total: 10120, now: 60)
        XCTAssertEqual(tokens.rate(now: 60, lookback: 60)!.perHour, 7200)
        XCTAssertNil(tokens.rate(now: 60, lookback: 3600))
        for minute in 2...5 { tokens.record(account: "A", total: 10000+Double(minute)*120, now: Double(minute*60)) }
        XCTAssertEqual(tokens.rate(now: 300)!.perHour, 7200)
        XCTAssertEqual(tokens.rate(now: 300)!.value(per: .minute), 120)
    }
    func testTokenCorrectionsAccountSwitchGapsAndMissingValuesReset() {
        for mode in 0...3 {
            var h = TokenHistory()
            for minute in 0...5 { h.record(account: "A", total: 1000+Double(minute), now: Double(minute*60)) }
            switch mode {
            case 0: h.record(account: "A", total: 1, now: 360)
            case 1: h.record(account: "B", total: 1010, now: 360)
            case 2: h.record(account: "A", total: 1010, now: 601)
            default: h.record(account: "A", total: nil, now: 360)
            }
            XCTAssertNil(h.rate(now: 601))
            XCTAssertLessThanOrEqual(h.samples.count, 1)
        }
    }
    func testPlanChangeInvalidatesQuotaBaseline() {
        var h = History()
        for minute in 0...5 {
            let item = WindowItem(id: "quota", name: "Codex", window: QuotaWindow(usedPercent: 20+Double(minute), windowDurationMins: 10080, resetsAt: 999999), planType: "plus")
            h.record(account: "A", items: [item], now: Double(minute*60))
        }
        let item = WindowItem(id: "quota", name: "Codex", window: QuotaWindow(usedPercent: 26, windowDurationMins: 10080, resetsAt: 999999), planType: "pro")
        h.record(account: "A", items: [item], now: 360)
        XCTAssertNil(h.rate(for: "quota", now: 360))
    }
    func testTranslationsAndSettingsRoundTrip() throws {
        for (_, translations) in L10n.table {
            for code in ["en", "zh-Hant", "zh-Hans"] { XCTAssertFalse(translations[code, default: ""].isEmpty) }
        }
        XCTAssertEqual(L10n(.english).text("settings"), "Settings")
        XCTAssertEqual(L10n(.zhHans).text("settings"), "设置")
        XCTAssertEqual(L10n(.zhHant).countdown(nil, now: 0), "重置時間未知")
        var settings = WidgetSettings(); settings.intervalValue = 3; settings.intervalUnit = .day; settings.language = .english
        XCTAssertEqual(try JSONDecoder().decode(WidgetSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
    func testOldHistoryMigrationWithAbsentPlanField() throws {
        let old = #"{"account":"A","series":{"quota":[{"timestamp":100,"used":25,"reset":99999,"duration":10080}]}}"#
        let history = try JSONDecoder().decode(History.self, from: Data(old.utf8))
        XCTAssertEqual(history.series["quota"]?.first?.used, 25)
        XCTAssertNil(history.series["quota"]?.first?.planType)
    }
}
