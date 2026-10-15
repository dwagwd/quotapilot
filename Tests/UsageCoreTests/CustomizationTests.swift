import XCTest
@testable import UsageCore

final class CustomizationTests: XCTestCase {
    func testOldPreferencesMigrateWithoutLosingLanguageOrInterval() throws {
        let data = Data(#"{"language":"zh-Hant","intervalValue":3,"intervalUnit":"day","rateUnit":"minute"}"#.utf8)
        let value = try JSONDecoder().decode(WidgetSettings.self, from: data)
        XCTAssertEqual(value.language, .zhHant)
        XCTAssertEqual(value.lookback, 259200)
        XCTAssertFalse(value.options.multiple)
        XCTAssertFalse(value.options.customColors)
        XCTAssertFalse(value.options.bridges)
    }
    func testInvalidQuotaPercentagesAreUnavailable() {
        for value in [Double.nan, .infinity, -1, 101] {
            XCTAssertNil(QuotaWindow(usedPercent: value, windowDurationMins: 60, resetsAt: nil).validUsedPercent)
        }
        for value in [0.0, 20.5, 100] {
            XCTAssertEqual(QuotaWindow(usedPercent: value, windowDurationMins: 60, resetsAt: nil).validUsedPercent, value)
        }
        XCTAssertNil(QuotaWindow(usedPercent: nil, windowDurationMins: nil, resetsAt: nil).validUsedPercent)
    }
    func testColorBoundsAndOptionsRoundTrip() throws {
        var value = WidgetSettings()
        value.options.multiple = true
        value.options.windowIDs = ["codex:primary", "claude:five_hour:primary"]
        value.options.foreground = RGBColor(0, 128, 255)
        value.options.energySaver = true
        XCTAssertTrue(value.isValid)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSettings.self, from: JSONEncoder().encode(value)), value)
        value.options.background.red = 256
        XCTAssertFalse(value.isValid)
        value.options.background.red = -1
        XCTAssertFalse(value.isValid)
    }
    func testProviderSnapshotIdentityAndTimestampValidation() throws {
        let raw = #"{"provider":"claude","account":"session-hash","updatedAt":1000,"limits":{"rateLimitsByLimitId":{"claude:five_hour":{"limitName":"Claude Code","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":99999}}}}}"#
        let snapshot = try JSONDecoder().decode(ProviderSnapshot.self, from: Data(raw.utf8))
        XCTAssertTrue(snapshot.isValid(now: 1001, expectedProvider: "claude"))
        XCTAssertFalse(snapshot.isValid(now: 1001, expectedProvider: "cursor"))
        XCTAssertFalse(snapshot.isValid(now: 990, expectedProvider: "claude"))
        XCTAssertEqual(snapshot.limits.windows().first?.window.usedPercent, 25)
    }
    func testPrimaryInterfaceHasTextOrFallbackForEveryKeyAndPercentNotation() {
        for language in WidgetLanguage.allCases where language != .system {
            for key in L10n.table.keys {
                let resolved = L10n.table[key]?[language.rawValue] ?? ((featureTranslations[key] ?? agentFallbackTranslations[key]) == nil ? nil : L10n.table[key]?["en"])
                XCTAssertNotNil(resolved, "\(language.rawValue): \(key)")
            }
            XCTAssertEqual(L10n(language).text("points"), "%")
        }
    }
    func testSecondsRateUnitAndPrecision() throws {
        XCTAssertEqual(TimeUnit.second.seconds, 1)
        XCTAssertEqual(Rate(perHour: 3600, observedSeconds: 600).value(per: .second), 1)
        XCTAssertFalse(TimeUnit.intervalUnits.contains(.second))
        XCTAssertEqual(TimeUnit.rateUnits.first, .second)
        let l = L10n(.english)
        XCTAssertEqual(l.rateNumber(2.0 / 3600), "0.0006")
        XCTAssertEqual(l.rateNumber(0.25), "0.25")
        XCTAssertEqual(l.unit(.second, short: true), "s")
        var settings = WidgetSettings(); settings.rateUnit = .second
        XCTAssertEqual(try JSONDecoder().decode(WidgetSettings.self, from: JSONEncoder().encode(settings)).rateUnit, .second)
    }
}
