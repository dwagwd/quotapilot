import XCTest
@testable import UsageCore

final class ModelAccountingTests: XCTestCase {
    private let turnContext = #"{"timestamp":"2026-11-20T03:00:00.000Z","type":"turn_context","payload":{"model":"GPT-6.2-Astra","effort":"high"}}"#
    private func codexTokens(_ time: String, total: Int) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":100,"reasoning_output_tokens":10}}}}"#
    }
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: Parsing model names

    func testClaudeAndGeminiEventsCarryNormalizedModel() throws {
        let claude = #"{"type":"assistant","timestamp":"2026-11-20T03:00:00Z","requestId":"r","message":{"id":"m","model":"Claude-Opus-5-5-20261101","usage":{"input_tokens":5,"output_tokens":7}}}"#
        XCTAssertEqual(AgentLogParser.claudeEvent(claude)?.model, "claude-opus-5-5-20261101")
        let synthetic = #"{"type":"assistant","timestamp":"2026-11-20T03:00:00Z","message":{"id":"m2","model":"<synthetic>","usage":{"input_tokens":5}}}"#
        XCTAssertNil(AgentLogParser.claudeEvent(synthetic)?.model)
        let gemini = #"{"id":"g1","timestamp":"2026-11-20T08:00:11.000Z","type":"gemini","model":"Gemini-4-Argon","tokens":{"input":10,"cached":0,"output":5,"thoughts":0,"tool":0}}"#
        XCTAssertEqual(AgentLogParser.geminiEvent(gemini)?.model, "gemini-4-argon")
        let grok = #"{"msg":"shell.turn.inference_done","sid":"s","ts":"2026-11-20T18:16:00.000Z","ctx":{"loop_index":1,"prompt_tokens":10,"cached_prompt_tokens":0,"completion_tokens":5,"reasoning_tokens":0}}"#
        XCTAssertNil(AgentLogParser.grokEvent(grok)?.model, "Grok logs name no model")
    }

    func testCodexModelComesFromTurnContextForwardAndBackward() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        try ([turnContext, codexTokens("2026-11-20T03:00:05.000Z", total: 1100)].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let scanner = AgentLogScanner(sources: [.init(provider: "codex", root: root, parse: AgentLogParser.codexEvent, parseModel: AgentLogParser.codexModelEvent)])
        XCTAssertEqual(scanner.scan(windowStart: 0).map(\.model), ["gpt-6.2-astra"])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((codexTokens("2026-11-20T03:01:00.000Z", total: 2200) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(scanner.scan(windowStart: 0).map(\.model), ["gpt-6.2-astra"], "an incremental read keeps the file's model")
    }

    func testCodexModelFoundInOlderChunkIsAppliedToNewerEvents() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let filler = #"{"type":"response_item","pad":""# + String(repeating: "a", count: 5 * 1_048_576) + #""}"#
        let text = [turnContext, filler, codexTokens("2026-11-20T03:00:05.000Z", total: 1100)].joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("big.jsonl"), atomically: true, encoding: .utf8)
        let scanner = AgentLogScanner(sources: [.init(provider: "codex", root: root, parse: AgentLogParser.codexEvent, parseModel: AgentLogParser.codexModelEvent)])
        XCTAssertEqual(scanner.scan(windowStart: 0).map(\.model), ["gpt-6.2-astra"])
    }

    // MARK: Persistence

    func testOldStoreFileWithoutModelsStillLoads() throws {
        var store = UsageStatsStore()
        store.add(AgentTokenEvent(provider: "claude", timestamp: 3_600, usage: TokenBreakdown(input: 10, output: 5), dedupeKey: "a", model: "claude-opus-5-5"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
        XCTAssertNotNil(object["modelHours"])
        object.removeValue(forKey: "modelHours"); object.removeValue(forKey: "activityHours")
        let old = try JSONDecoder().decode(UsageStatsStore.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.tokenTotals(since: 0, now: 10_000)["claude"]?.total, 15)
        let input = old.statsInput(since: 0, now: 10_000)
        XCTAssertEqual(input.rows, [ModelUsage(provider: "claude", model: nil, usage: TokenBreakdown(input: 10, output: 5), calls: 0)])
        XCTAssertEqual(input.activeSlots, 0)
    }

    func testStoreKeepsModelsCallsAndActivityAcrossSaving() throws {
        var store = UsageStatsStore()
        let call = { (out: Double, t: Double) in AgentTokenEvent(provider: "claude", timestamp: t, usage: TokenBreakdown(input: 5, output: out), dedupeKey: "m", model: "claude-opus-5-5") }
        store.add(call(1, 3_600)); store.add(call(9, 3_610))            // one call, rewritten with more output
        store.add(AgentTokenEvent(provider: "claude", timestamp: 3_600 + 1_000, usage: TokenBreakdown(input: 1), dedupeKey: "n", model: "claude-opus-5-5"))
        var restored = try JSONDecoder().decode(UsageStatsStore.self, from: JSONEncoder().encode(store))
        let input = restored.statsInput(since: 0, now: 10_000)
        XCTAssertEqual(input.rows.count, 1)
        XCTAssertEqual(input.rows[0].calls, 2, "a streamed rewrite is not another call")
        XCTAssertEqual(input.rows[0].usage.output, 9)
        XCTAssertEqual(input.activeSlots, 2, "3600s and 4600s fall in different five-minute slots")
        restored.prune(now: 10_000 + 40 * 86400)
        XCTAssertTrue(restored.statsInput(since: 0, now: 10_000 + 40 * 86400).rows.isEmpty)
    }

    func testDistinctModelsAreCappedAndFoldedIntoOther() {
        var store = UsageStatsStore(), ledger = AgentTokenLedger()
        for index in 0..<(ModelKey.maxDistinct + 5) {
            let event = AgentTokenEvent(provider: "claude", timestamp: 3_600, usage: TokenBreakdown(input: 1), dedupeKey: "k\(index)", model: "m\(index)")
            store.add(event); ledger.add(event)
        }
        for input in [store.statsInput(since: 0, now: 10_000), ledger.statsInput(since: 0, now: 10_000)] {
            XCTAssertLessThanOrEqual(input.rows.count, ModelKey.maxDistinct + 1)
            XCTAssertEqual(input.rows.reduce(0) { $0 + $1.usage.total }, Double(ModelKey.maxDistinct + 5))
            XCTAssertEqual(input.rows.first { $0.model == "other" }?.usage.total, 5)
        }
    }

    func testLedgerCountsCallsPerBucketOnce() {
        var ledger = AgentTokenLedger()
        let a = AgentTokenEvent(provider: "codex", timestamp: 1_000, usage: TokenBreakdown(input: 10), dedupeKey: "a", model: "gpt-6-1-sol")
        ledger.add(a); ledger.add(a)
        ledger.add(AgentTokenEvent(provider: "codex", timestamp: 1_000, usage: TokenBreakdown(input: 10, output: 4), dedupeKey: "a", model: "gpt-6-1-sol"))
        ledger.add(AgentTokenEvent(provider: "codex", timestamp: 2_000, usage: TokenBreakdown(input: 1), dedupeKey: "b", model: "gpt-6-1-sol"))
        let input = ledger.statsInput(since: 0, now: 5_000)
        XCTAssertEqual(input.rows, [ModelUsage(provider: "codex", model: "gpt-6-1-sol", usage: TokenBreakdown(input: 11, output: 4), calls: 2)])
        XCTAssertEqual(input.activeSlots, 2)
    }

    // MARK: Prices and local models

    func testPriceMatchingIsTolerant() {
        for id in ["claude-opus-5-5", "Claude-Opus-5-5-20261101", "claude-opus-5-5[1m]", "anthropic/claude-opus-5-5", "us.anthropic.claude-opus-5-5-v1:0",
                   "claude-opus-5-5@20261101", "claude-opus-5.5"] {
            XCTAssertEqual(ModelPrices.price(for: id)?.id, "claude-opus-5-5", id)
        }
        XCTAssertEqual(ModelPrices.price(for: "gpt-6.1-sol")?.id, "gpt-6-1-sol")
        XCTAssertEqual(ModelPrices.price(for: "models/gemini-4-carbon-preview-1105")?.id, "gemini-4-carbon")
        XCTAssertEqual(ModelPrices.price(for: "grok-4.7")?.id, "grok-4-7")
        XCTAssertNil(ModelPrices.price(for: "gpt-6-1-sol-mini"), "a different model is not matched by prefix")
        XCTAssertNil(ModelPrices.price(for: "unheard-of-model"))
        XCTAssertNil(ModelPrices.price(for: nil))
    }

    func testLocalModelDetection() {
        for id in ["qwen3:8b", "llama3.1:70b", "deepseek-r1:14b", "gemma3:4b-it-qat", "gpt-oss:20b", "ollama/mistral", "lmstudio-community/foo", "foo-q4.gguf", "hf.co/bar/baz"] {
            XCTAssertTrue(ModelIdentity.isLocal(id), id)
        }
        for id in ["claude-opus-5-5", "anthropic.claude-opus-5-5-v1:0", "gpt-6-1-sol", "gemini-4-carbon", "llama-3-8b", ""] {
            XCTAssertFalse(ModelIdentity.isLocal(id), id)
        }
    }

    // MARK: Cost, cache and shares

    func testCostCacheAndShareMath() throws {
        // Opus 5.5: input $4, cache read $0.20, cache write $5, output $20 per million.
        let opus = ModelUsage(provider: "claude", model: "claude-opus-5-5",
                              usage: TokenBreakdown(input: 1_000_000, cacheRead: 8_000_000, cacheWrite: 1_000_000, output: 500_000, reasoning: 0), calls: 10)
        // Grok has a cache-read price but the model here is unknown to the table: not priced.
        let mystery = ModelUsage(provider: "claude", model: "mystery-1", usage: TokenBreakdown(input: 100, output: 100), calls: 3)
        let local = ModelUsage(provider: "claude", model: "qwen3:8b", usage: TokenBreakdown(input: 1_000_000, output: 1_000_000), calls: 4)
        let codex = ModelUsage(provider: "codex", model: "gpt-6-1-sol", usage: TokenBreakdown(input: 100_000, cacheRead: 900_000, output: 100_000, reasoning: 40_000), calls: 5)
        let report = UsageReport(UsageStatsInput(rows: [opus, mystery, local, codex], activeSlots: 3))
        // 1*4 + 8*0.2 + 1*5 + 0.5*20 = 20.6 ; sol: 0.1*2 + 0.9*0.1 + 0.1*10 = 1.29
        XCTAssertEqual(report.costUSD, 20.6 + 1.29, accuracy: 1e-9)
        XCTAssertEqual(report.unpricedTokens, 200)
        XCTAssertEqual(report.localTokens, 2_000_000)
        XCTAssertEqual(report.calls, 22)
        XCTAssertEqual(report.activeMinutes, 15)
        // savings = 8M*(4-0.2) + 0.9M*(2-0.1) per million
        XCTAssertEqual(report.cacheSavingsUSD, 8 * 3.8 + 0.9 * 1.9, accuracy: 1e-9)
        let prompt = 1_000_000.0 + 8_000_000 + 1_000_000 + 100_000 + 900_000 + 1_000_000 + 100
        XCTAssertEqual(try XCTUnwrap(report.cacheHitRate), 8_900_000 / prompt, accuracy: 1e-9)
        XCTAssertEqual(report.categories.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
        let reasoning = try XCTUnwrap(report.categories.first { $0.kind == .reasoning })
        XCTAssertEqual(reasoning.tokens, 40_000)
        XCTAssertEqual(try XCTUnwrap(report.categories.first { $0.kind == .output }).tokens, 500_000 + 100 + 1_000_000 + 60_000)
        XCTAssertEqual(try XCTUnwrap(report.categories.first { $0.kind == .newInput }).tokens, 1_000_000 + 1_000_000 + 100 + 1_000_000 + 100_000)
        XCTAssertEqual(Set(report.providers.map(\.provider)), ["claude", "codex", "local"], "local models form their own provider")
        XCTAssertEqual(report.models.first { $0.model == "qwen3:8b" }?.costUSD, 0)
        XCTAssertEqual(report.models.first { $0.model == "qwen3:8b" }?.status, .local)
        XCTAssertNil(report.models.first { $0.model == "mystery-1" }?.costUSD)
        XCTAssertEqual(report.providers.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-9)
    }

    func testMissingCachePriceFallsBackToInputPrice() {
        // gpt-6-1-sol has no cache-write price: writes cost the input price, and only reads count as savings.
        let usage = TokenBreakdown(input: 0, cacheRead: 1_000_000, cacheWrite: 1_000_000, output: 0)
        let price = ModelPrice(id: "x", input: 2, output: 10, cacheRead: nil, cacheWrite: nil)
        XCTAssertEqual(UsageReport.cost(usage, price), 4, accuracy: 1e-9)
        XCTAssertEqual(UsageReport.savings(usage, price), 0)
        XCTAssertEqual(UsageReport(UsageStatsInput(rows: [], activeSlots: 0)).cacheHitRate, nil)
    }

    func testEveryGeneratedPriceIsSane() {
        XCTAssertFalse(ModelPrices.entries.isEmpty)
        for price in ModelPrices.entries {
            XCTAssertGreaterThan(price.input, 0, price.id)
            XCTAssertGreaterThan(price.output, 0, price.id)
            XCTAssertLessThanOrEqual(price.cacheRead ?? 0, price.input, price.id)
        }
    }

    func testStatsTextsExistInEveryLanguage() {
        for language in WidgetLanguage.allCases where language != .system {
            for key in statsTranslations.keys {
                XCTAssertNotNil(statsTranslations[key]?[language.rawValue], "\(language.rawValue): \(key)")
            }
        }
    }
}
