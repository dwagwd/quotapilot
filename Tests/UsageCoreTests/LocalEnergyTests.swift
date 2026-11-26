import XCTest
@testable import UsageCore

final class LocalEnergyTests: XCTestCase {
    private func mac(_ chip: String, memory: Double = 36, gpu: Int? = nil) -> HardwareInfo {
        HardwareInfo(os: "macos", osMajor: 26, cpuName: chip, memoryGiB: memory, gpuCores: gpu)
    }
    private func event(_ id: String, prompt: Double = 1000, completion: Double = 500, seconds: Double? = 30, promptSeconds: Double? = nil, genSeconds: Double? = nil) -> LocalLLMEvent {
        LocalLLMEvent(id: id, t: 1000, backend: "ollama", via: "poll", model: "qwen3:30b", prompt: prompt, completion: completion,
                      promptSeconds: promptSeconds, genSeconds: genSeconds, seconds: seconds)
    }

    func testPriceIsEmptyByDefaultAndNothingIsComputedFromIt() {
        let settings = EnergySettings()
        XCTAssertFalse(settings.hasPrice)
        XCTAssertNil(settings.pricePerKWh)
        let report = LocalEnergyReport(events: [event("a")], reference: nil, settings: settings, hardware: mac("Apple M4 Max"), locale: Locale(identifier: "en_US"))
        XCTAssertNil(report.cost)
        XCTAssertNil(report.costPerMillionTokens)
        var zero = EnergySettings(); zero.pricePerKWh = 0
        XCTAssertFalse(zero.hasPrice)
    }

    func testPowerDefaultsFollowTheChipTier() {
        XCTAssertEqual(DevicePower.estimate(for: mac("Apple M4")).watts, 20)
        XCTAssertEqual(DevicePower.estimate(for: mac("Apple M4 Pro")).watts, 40)
        XCTAssertEqual(DevicePower.estimate(for: mac("Apple M4 Max")).watts, 70)
        XCTAssertEqual(DevicePower.estimate(for: mac("Apple M3 Ultra")).watts, 120)
        XCTAssertEqual(DevicePower.estimate(for: mac("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz")).watts, DevicePower.genericWatts)
        XCTAssertEqual(DevicePower.estimate(for: HardwareInfo(os: "linux", osMajor: 0, cpuName: nil, memoryGiB: 16)).watts, DevicePower.genericWatts)
        var settings = EnergySettings()
        XCTAssertEqual(settings.resolvedWatts(mac("Apple M4 Max")), 70)
        settings.watts = 55
        XCTAssertEqual(settings.resolvedWatts(mac("Apple M4 Max")), 55, "the user's value wins")
    }

    func testCostFromMeasuredSecondsPerMonthAndPerMillionTokens() {
        var settings = EnergySettings()
        settings.pricePerKWh = 0.30; settings.currency = "EUR"; settings.watts = 100; settings.usdRate = 0.9
        // 2 events x 1800 s = 1 hour at 100 W = 0.1 kWh = 0.03 EUR for 3,000 tokens.
        let events = [event("a", prompt: 1000, completion: 500, seconds: 1800), event("b", prompt: 1000, completion: 500, seconds: 1800)]
        let report = LocalEnergyReport(events: events, reference: "claude-sonnet-5-5", settings: settings, hardware: mac("Apple M4"), locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(report.kWh, 0.1, accuracy: 1e-9)
        XCTAssertEqual(report.cost ?? 0, 0.03, accuracy: 1e-9)
        XCTAssertEqual(report.currency, "EUR")
        XCTAssertEqual(report.costPerMillionTokens ?? 0, 0.03 / 0.003, accuracy: 1e-6)
        XCTAssertEqual(report.coverage, 1)
        // The cloud side is the reference model's price for the same tokens, converted with the user's rate.
        let usd = LocalLLMReport.cost(prompt: 2000, cached: 0, completion: 1000, price: LocalLLMReference.resolve("claude-sonnet-5-5"))
        XCTAssertEqual(report.cloudCostUSD, usd, accuracy: 1e-12)
        XCTAssertEqual(report.cloudCost ?? 0, usd * 0.9, accuracy: 1e-12)
    }

    func testEventsWithoutATimeAreLeftOutAndCoverageSaysSo() {
        var settings = EnergySettings(); settings.pricePerKWh = 0.2; settings.currency = "USD"; settings.watts = 60
        let events = [event("timed", seconds: 3600), event("untimed", seconds: nil), event("split", seconds: nil, promptSeconds: 10, genSeconds: 20)]
        let report = LocalEnergyReport(events: events, reference: nil, settings: settings, hardware: mac("Apple M4"), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(report.seconds, 3630, accuracy: 1e-9)
        XCTAssertEqual(report.measuredTokens, 3000, accuracy: 1e-9)
        XCTAssertEqual(report.totalTokens, 4500, accuracy: 1e-9)
        XCTAssertEqual(report.coverage, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(report.cloudCost, report.cloudCostUSD, "USD needs no exchange rate")
    }

    func testNoCloudConversionWithoutARate() {
        var settings = EnergySettings(); settings.pricePerKWh = 30; settings.currency = "JPY"
        let report = LocalEnergyReport(events: [event("a")], reference: nil, settings: settings, hardware: mac("Apple M4"), locale: Locale(identifier: "ja_JP"))
        XCTAssertNil(report.cloudCost)
        XCTAssertNotNil(report.cost)
        XCTAssertEqual(settings.rate(Locale(identifier: "ja_JP")), nil)
    }

    func testValidationAndCurrency() {
        XCTAssertNil(EnergySettings.validate(price: 0.25, watts: 70, rate: 150, currency: "jpy"))
        XCTAssertNotNil(EnergySettings.validate(price: -1))
        XCTAssertNotNil(EnergySettings.validate(watts: 0))
        XCTAssertNotNil(EnergySettings.validate(watts: 99_999))
        XCTAssertNotNil(EnergySettings.validate(rate: 0))
        XCTAssertNotNil(EnergySettings.validate(currency: "EURO"))
        var settings = EnergySettings()
        XCTAssertEqual(settings.resolvedCurrency(Locale(identifier: "ja_JP")), "JPY")
        XCTAssertEqual(settings.resolvedCurrency(Locale(identifier: "de_DE")), "EUR")
        settings.currency = "gbp"
        XCTAssertEqual(settings.resolvedCurrency(Locale(identifier: "ja_JP")), "GBP")
    }

    func testSettingsSurviveARoundTripInsideTheLocalSettings() throws {
        var local = LocalLLMSettings()
        XCTAssertNil(local.energy, "nothing stored until the user enters something")
        local.energySettings.pricePerKWh = 0.18; local.energySettings.currency = "USD"
        let decoded = try JSONDecoder().decode(LocalLLMSettings.self, from: JSONEncoder().encode(local))
        XCTAssertEqual(decoded.energySettings.pricePerKWh, 0.18)
        // Settings saved before electricity existed still decode.
        XCTAssertNil(try JSONDecoder().decode(LocalLLMSettings.self, from: Data(#"{"enabled":true}"#.utf8)).energy)
    }

    func testHardwareBucketsAreCoarse() {
        XCTAssertEqual(mac("Apple M4 Max", memory: 36).sharedMemoryTier, 48)
        XCTAssertEqual(mac("Apple M4 Max", memory: 64).sharedMemoryTier, 64)
        XCTAssertEqual(mac("x", memory: 15.6).sharedMemoryTier, 16)
        XCTAssertEqual(mac("x", memory: 512).sharedMemoryTier, 256)
        XCTAssertEqual(mac("Apple M4 Max", gpu: 40).sharedGPUCoreBucket, 40)
        XCTAssertEqual(mac("Apple M4 Max", gpu: 32).sharedGPUCoreBucket, 40)
        XCTAssertEqual(mac("Apple M4", gpu: 10).sharedGPUCoreBucket, 10)
        XCTAssertNil(mac("Apple M4").sharedGPUCoreBucket)
        XCTAssertEqual(mac("Apple M4 Max").sharedChip, "Apple M4 Max")
        XCTAssertEqual(mac("Apple M3").sharedChip, "Apple M3")
        XCTAssertEqual(mac("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz").sharedChip, "Intel", "no model number leaves an Intel machine")
        XCTAssertEqual(mac("AMD Ryzen 9 7950X 16-Core Processor").sharedChip, "AMD")
        XCTAssertEqual(HardwareInfo(os: "linux", osMajor: 6, cpuName: "x", memoryGiB: 8).sharedOS.major, 0)
        XCTAssertEqual(mac("Apple M4").sharedOS.family, "macos")
        XCTAssertEqual(mac("Apple M4").sharedOS.major, 26)
    }

    func testMoneyFormattingFollowsTheLocale() {
        XCTAssertEqual(L10n(.german).money(1.5, currency: "EUR").replacingOccurrences(of: "\u{a0}", with: " "), "1,50 €")
        XCTAssertTrue(L10n(.english).money(0.0042, currency: "USD").contains("0.0042"))
        XCTAssertTrue(L10n(.japanese).money(63, currency: "JPY").contains("63"))
    }

    func testEnergyTextsExistInEveryLanguage() {
        for (key, values) in energyTranslations {
            for language in WidgetLanguage.allCases where language != .system {
                XCTAssertFalse(values[language.rawValue, default: ""].isEmpty, "\(key) \(language.rawValue)")
            }
        }
    }
}
