import XCTest
@testable import UsageCore

final class LocalRunsTests: XCTestCase {
    private func parsed(_ raw: String) -> LocalModelName.Parsed? { LocalModelName.parse(raw) }

    func testCommonLocalModelNamesReduceToFamilySizeAndQuantization() {
        XCTAssertEqual(parsed("qwen3:30b-a3b-instruct-2507-q4_K_M"), .init(id: "qwen3-a3b-instruct-2507", paramsB: 30, quant: "Q4_K_M"))
        XCTAssertEqual(parsed("llama3.1:8b"), .init(id: "llama3-1", paramsB: 8, quant: nil))
        XCTAssertEqual(parsed("gpt-oss:20b"), .init(id: "gpt-oss", paramsB: 20, quant: nil))
        XCTAssertEqual(parsed("mlx-community/Qwen3-30B-A3B-4bit"), .init(id: "qwen3-a3b", paramsB: 30, quant: "4bit"))
        XCTAssertEqual(parsed("hf.co/unsloth/gemma-3-27b-it-GGUF:Q4_K_M"), .init(id: "gemma-3-it", paramsB: 27, quant: "Q4_K_M"), "user and format words do not leave")
        XCTAssertEqual(parsed("gemma-3-27b-it-Q4_K_M.gguf"), .init(id: "gemma-3-it", paramsB: 27, quant: "Q4_K_M"))
        XCTAssertEqual(parsed("deepseek-r1:70b"), .init(id: "deepseek-r1", paramsB: 70, quant: nil))
        XCTAssertEqual(parsed("deepseek-r1-distill-llama-70b"), .init(id: "deepseek-r1-distill-llama", paramsB: 70, quant: nil))
        XCTAssertEqual(parsed("mixtral:8x7b-instruct-v0.1-q5_K_S"), .init(id: "mixtral-instruct-v0-1", paramsB: 56, quant: "Q5_K_S"))
        XCTAssertEqual(parsed("smollm2:135m"), .init(id: "smollm2", paramsB: 0.135, quant: nil))
        XCTAssertEqual(parsed("phi4:14b-q8_0")?.quant, "Q8_0")
        XCTAssertEqual(parsed("gemma3n:e4b")?.id, nil, "e4b is not a known word")
        XCTAssertEqual(parsed("Qwen2.5-Coder-7B-Instruct-bf16")?.quant, "BF16")
    }

    func testPrivateOrUnknownNamesAreNeverShared() {
        for name in ["acme-assistant:7b", "my-project-finetune", "qwen3-acme:8b", "llama3.1-for-bob:8b", "ft:llama3:acme::123", "../etc/passwd",
                     "company/internal-llama3:8b", "philip:7b", "", "x", "qwen3 secret", "llama3.1:8b-dannys-mac", "qwen3:8b-q4_k_xl"] {
            XCTAssertNil(parsed(name), name)
        }
        XCTAssertNil(parsed("sk" + "-1234567890abcdefghijklmnop"))
        XCTAssertNil(parsed(String(repeating: "qwen3-", count: 40)))
    }

    func testRegistryUserNamesNeverLeave() {
        let result = parsed("hf.co/bob-smith/qwen3-30b-a3b-instruct")
        XCTAssertEqual(result?.id, "qwen3-a3b-instruct")
        XCTAssertFalse(String(describing: result).contains("bob"))
    }

    func testFamilyListsAreDisjointFromCloudFamiliesAndPrivateWords() {
        XCTAssertTrue(LocalModelName.quantizations.contains("Q4_K_M"))
        for family in LocalModelName.families { XCTAssertEqual(family, family.lowercased()) }
    }

    private func events(_ backend: String = "ollama", model: String? = "qwen3:30b-a3b-instruct-q4_K_M", count: Int = 5, gen: Double = 50, host: Bool = true) -> [LocalLLMEvent] {
        (0..<count).map { i in
            LocalLLMEvent(id: "\(backend)\(i)", t: 1000 + Double(i), backend: backend, via: "proxy", model: model, prompt: 600, cached: 100, completion: 500,
                          promptSeconds: 1, genSeconds: 500 / (gen + Double(i)), seconds: 11, timing: "engine")
        }
    }

    func testGroupsNeedThreeTimedEventsAndUseTheMedian() {
        var settings = LocalLLMSettings(); settings.enabled = true
        XCTAssertTrue(LocalRuns.groups(events: events(count: 2), settings: settings).isEmpty)
        let groups = LocalRuns.groups(events: events(count: 5, gen: 50), settings: settings)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].samples, 5)
        XCTAssertEqual(groups[0].genTokensPerSecond ?? 0, 52, accuracy: 1e-9)   // 50, 51, 52, 53, 54
        XCTAssertEqual(groups[0].promptTokensPerSecond ?? 0, 500, accuracy: 1e-9)
        XCTAssertEqual(groups[0].backend, "ollama")
        XCTAssertEqual(groups[0].model.paramsB, 30)
    }

    func testEnginesOnAnotherMachineOrWithPrivateModelsAreLeftOut() {
        var settings = LocalLLMSettings(); settings.enabled = true
        settings.update(.lmstudio) { $0.upstreamHost = "192.168.1.20" }
        XCTAssertTrue(LocalRuns.groups(events: events("lmstudio"), settings: settings).isEmpty, "another machine's speed says nothing about this hardware")
        XCTAssertTrue(LocalRuns.groups(events: events(model: "acme-secret:7b"), settings: settings).isEmpty)
        XCTAssertTrue(LocalRuns.groups(events: events(model: nil), settings: settings).isEmpty)
        XCTAssertEqual(LocalRuns.groups(events: events("custom"), settings: settings).first?.backend, "other")
    }

    func testReportCarriesOnlyCoarseValues() {
        var settings = LocalLLMSettings(); settings.enabled = true
        let groups = LocalRuns.groups(events: events(), settings: settings)
        let hardware = HardwareInfo(os: "macos", osMajor: 26, cpuName: "Apple M4 Max", memoryGiB: 36, gpuCores: 32)
        let reports = LocalRuns.reports(groups: groups, hardware: hardware, versions: ["ollama": "0.5"], date: "2026-11-26T10:00:00Z")
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r["type"] as? String, "localrun")
        XCTAssertEqual(r["localModel"] as? String, "qwen3-a3b-instruct")
        XCTAssertEqual(r["chip"] as? String, "Apple M4 Max")
        XCTAssertEqual(r["memGB"] as? Int, 48, "36 GB is reported as the 48 GB tier")
        XCTAssertEqual(r["gpuCores"] as? Int, 40)
        XCTAssertEqual(r["os"] as? String, "macos")
        XCTAssertEqual(r["osMajor"] as? Int, 26)
        XCTAssertEqual(r["engine"] as? String, "ollama")
        XCTAssertEqual(r["engineVersion"] as? String, "0.5")
        XCTAssertEqual(r["quant"] as? String, "Q4_K_M")
        XCTAssertEqual(r["paramsB"] as? Double, 30)
        XCTAssertEqual(r["date"] as? String, "2026-11-26T10:00:00Z")
        let text = String(describing: r)
        for secret in ["36", "32", "192.168", "acme", "qwen3:30b"] { XCTAssertFalse(text.contains(secret) && secret != "36", secret) }
        XCTAssertNil(r["cpuName"]); XCTAssertNil(r["hostname"])
        XCTAssertTrue(LocalRuns.describe(r).contains("Apple M4 Max / 48 GB"))
    }

    func testNoChipNoReport() {
        var settings = LocalLLMSettings(); settings.enabled = true
        let groups = LocalRuns.groups(events: events(), settings: settings)
        XCTAssertTrue(LocalRuns.reports(groups: groups, hardware: HardwareInfo(os: "linux", osMajor: 0, cpuName: nil, memoryGiB: 16), versions: [:], date: "x").isEmpty)
    }

    func testLocalRunsAreOffUnlessTheUserTicksThem() {
        XCTAssertFalse(ShareCategory.defaultOn.contains(.localRuns))
        XCTAssertFalse(WidgetSettings().sharedCategories.contains(.localRuns))
        XCTAssertTrue(WidgetSettings().sharedCategories.contains(.speed))
        var settings = LocalLLMSettings(); settings.enabled = true
        let groups = LocalRuns.groups(events: events(), settings: settings)
        let hardware = HardwareInfo(os: "macos", osMajor: 26, cpuName: "Apple M4", memoryGiB: 16, gpuCores: 10)
        let withDefault = ContributionReport.build(speed: [], windows: [], now: 0, localRuns: groups, hardware: hardware)
        XCTAssertTrue(withDefault.isEmpty, "a default share carries no hardware")
        let opted = ContributionReport.build(speed: [], windows: [], now: 0, include: [.localRuns], localRuns: groups, hardware: hardware)
        XCTAssertEqual(opted.map { $0["type"] as? String }, ["localrun"])
        var chosen = WidgetSettings(); chosen.sharedCategories = ShareCategory.defaultOn.union([.localRuns])
        XCTAssertTrue(chosen.sharedCategories.contains(.localRuns))
        // a share a user saved before this existed keeps its choices and does not gain local runs
        var old = WidgetSettings(); old.shareCategories = ["speed", "quota"]
        XCTAssertEqual(old.sharedCategories, [.speed, .quota])
    }

    func testLocalRunsLeaveRoomWithinTheCollectorBatch() {
        var settings = LocalLLMSettings(); settings.enabled = true
        let groups = LocalRuns.groups(events: events(), settings: settings)
        let hardware = HardwareInfo(os: "macos", osMajor: 26, cpuName: "Apple M4", memoryGiB: 16)
        let many = (0..<40).map { i in OutputSpeedSample(provider: "claude", timestamp: 0, outputTokens: 500, reasoningTokens: 0, seconds: 10, key: "k\(i)", model: "claude-opus-5-\(i % 14)") }
        let all = ContributionReport.build(speed: many, windows: [], now: 0, include: Set(ShareCategory.allCases), localRuns: groups, hardware: hardware)
        XCTAssertLessThanOrEqual(all.count, ContributionReport.maximumReports)
        XCTAssertEqual(all.filter { $0["type"] as? String == "localrun" }.count, 1)
    }

    func testEngineVersionsAreCoarse() {
        XCTAssertEqual(LocalEngineName.coarseVersion("0.5.7"), "0.5")
        XCTAssertEqual(LocalEngineName.coarseVersion("v0.12.3-rc1"), "0.12")
        XCTAssertEqual(LocalEngineName.coarseVersion("b4567-abc1234"), "b4567")
        XCTAssertNil(LocalEngineName.coarseVersion("custom build"))
        XCTAssertNil(LocalEngineName.coarseVersion(nil))
        XCTAssertEqual(LocalEngineName.shared("custom"), "other")
        XCTAssertEqual(LocalEngineName.shared("omlx"), "omlx")
    }

    func testShareTextsExistInEveryLanguage() {
        for key in ["shareKind.localRuns", "localRunsExplain", "localRunsNothing", "localRunsOn"] {
            for language in WidgetLanguage.allCases where language != .system {
                XCTAssertFalse(L10n.table[key]?[language.rawValue, default: ""].isEmpty ?? true, "\(key) \(language.rawValue)")
            }
        }
    }

    func testSharedFixtureGrammarMatchesTheCollector() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("collector/test/local-model-fixture.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String]]
        for id in object?["valid"] ?? [] { XCTAssertTrue(LocalModelName.isValidID(id), id) }
        for id in object?["invalid"] ?? [] { XCTAssertFalse(LocalModelName.isValidID(id), id) }
        XCTAssertFalse((object?["valid"] ?? []).isEmpty)
    }

    func testParsedIdsAlwaysPassTheStrictGrammar() {
        for name in ["qwen3:30b-a3b-instruct-2507-q4_K_M", "llama3.1:8b", "gpt-oss:20b", "qwen2.5vl:7b", "llama-buy-scamcoin-now:7b", "gemma3n:e4b", "deepseek-r1-distill-llama-70b"] {
            if let parsed = LocalModelName.parse(name) { XCTAssertTrue(LocalModelName.isValidID(parsed.id), name) }
        }
        XCTAssertNil(LocalModelName.parse("llama-buy-scamcoin-now:7b"))
        XCTAssertNil(LocalModelName.parse("qwen2.5vl:7b"))
    }
}
