import XCTest
@testable import UsageCore

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

/// A scripted HTTP server on an ephemeral loopback port, built on the same sockets as the proxy.
final class FakeServer {
    struct Reply { var slices: [Data]; var pause: Double = 0; var closeAfter = false }
    let listener: Int32
    let port: Int
    private let lock = NSLock()
    private var stop = false
    private(set) var requests: [(method: String, target: String, headers: [String: String], body: Data)] = []
    var handler: (String, String) -> Reply

    init(handler: @escaping (String, String) -> Reply) throws {
        self.handler = handler
        listener = try LocalSockets.listenLoopback(port: 0)
        port = LocalSockets.boundPort(listener)
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let done = stop; lock.unlock()
                if done { break }
                guard let client = LocalSockets.acceptConnection(listener, waitMilliseconds: 100) else { continue }
                Thread.detachNewThread { [self] in serve(client) }
            }
            LocalSockets.closeSocket(listener)
        }
    }
    func shutdown() { lock.lock(); stop = true; lock.unlock() }

    private func serve(_ client: Int32) {
        defer { LocalSockets.closeSocket(client) }
        let parser = HTTPStreamParser(role: .request)
        var head: HTTPStreamParser.Head?
        var body = Data()
        var closeNow = false
        parser.onHead = { head = $0; body = Data() }
        parser.onBody = { body.append($0) }
        parser.onMessageEnd = { [self] in
            guard let current = head else { return }
            lock.lock(); requests.append((current.method, current.target, current.headers, body)); lock.unlock()
            let reply = handler(current.method, current.target)
            for slice in reply.slices {
                _ = slice.withUnsafeBytes { LocalSockets.sendAll(client, $0) }
                if reply.pause > 0 { Thread.sleep(forTimeInterval: reply.pause) }
            }
            if reply.closeAfter { closeNow = true }
        }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !closeNow {
            let count = LocalSockets.receive(client, into: &buffer)
            if count <= 0 { break }
            parser.feed(Data(buffer[0..<count]))
        }
    }
}

/// Sends each request in turn on one connection and collects the answer bytes: `expected` per request (the last may be
/// shorter if the connection ends; nothing is read for 0). Gives up after 4 seconds of silence.
func exchange(port: Int, steps: [(request: Data, expected: Int)]) -> Data {
    guard let fd = LocalSockets.connect(host: "127.0.0.1", port: port, timeoutMilliseconds: 2000) else { return Data() }
    defer { LocalSockets.closeSocket(fd) }
    LocalSockets.setReceiveTimeout(fd, seconds: 4)
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    var wanted = 0
    for step in steps {
        _ = step.request.withUnsafeBytes { LocalSockets.sendAll(fd, $0) }
        wanted += step.expected
        while received.count < wanted {
            let count = LocalSockets.receive(fd, into: &buffer)
            if count <= 0 { return received }
            received.append(contentsOf: buffer[0..<count])
        }
    }
    return received
}
func exchange(port: Int, request: Data, expected: Int) -> Data { exchange(port: port, steps: [(request, expected)]) }

final class EventCollector {
    private let lock = NSLock()
    private var items: [LocalLLMEvent] = []
    func add(_ event: LocalLLMEvent) { lock.lock(); items.append(event); lock.unlock() }
    var events: [LocalLLMEvent] { lock.lock(); defer { lock.unlock() }; return items }
    func wait(count: Int, timeout: Double = 3) -> [LocalLLMEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while events.count < count, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        return events
    }
}

#endif

final class LocalLLMTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func scan(_ kind: LocalLineScanner.Kind, _ text: String, split: Int? = nil) -> LocalUsageFields {
        var scanner = LocalLineScanner(kind: kind)
        let bytes = Array(text.utf8)
        let size = split ?? bytes.count
        var index = 0
        while index < bytes.count { scanner.feed(Data(bytes[index..<min(bytes.count, index + size)])); index += size }
        scanner.finish()
        return scanner.accumulator.fields
    }

    // MARK: Response parsing

    func testOpenAIJSONUsage() {
        let body = #"{"id":"x","model":"Qwen3-8B","choices":[{"message":{"content":"SECRET TEXT"}}],"usage":{"prompt_tokens":44,"completion_tokens":48,"total_tokens":92,"prompt_tokens_details":{"cached_tokens":4},"completion_tokens_details":{"reasoning_tokens":7}}}"#
        let f = LocalJSONBody.fields(data(body))
        XCTAssertEqual(f.model, "Qwen3-8B")
        XCTAssertEqual(f.prompt, 44); XCTAssertEqual(f.completion, 48); XCTAssertEqual(f.cached, 4); XCTAssertEqual(f.reasoning, 7)
        XCTAssertFalse(f.engineTimings)
    }

    func testLlamaCppTimingsOverrideCachedPromptAndGiveSpeeds() {
        let body = #"{"model":"gguf","usage":{"completion_tokens":35,"prompt_tokens":237,"total_tokens":272},"timings":{"cache_n":236,"prompt_n":1,"prompt_ms":30.958,"predicted_n":35,"predicted_ms":661.064,"predicted_per_second":52.9}}"#
        let f = LocalJSONBody.fields(data(body))
        XCTAssertEqual(f.prompt, 237); XCTAssertEqual(f.cached, 236); XCTAssertEqual(f.completion, 35)
        XCTAssertEqual(f.promptSeconds ?? 0, 0.030958, accuracy: 1e-9)
        XCTAssertEqual(f.genSeconds ?? 0, 0.661064, accuracy: 1e-9)
        XCTAssertTrue(f.engineTimings)
    }

    func testSSEWithFinalUsageChunk() {
        let sse = """
        data: {"id":"1","model":"qwen3:8b","choices":[{"delta":{"content":"Hi"}}],"usage":null}

        data: {"id":"1","model":"qwen3:8b","choices":[{"delta":{"content":" there"}}],"usage": null}

        data: {"id":"1","model":"qwen3:8b","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":5,"total_tokens":25,"prompt_tokens_details":{"cached_tokens":8}}}

        data: [DONE]


        """
        for split in [nil, 1, 7] {
            let f = scan(.sse, sse, split: split)
            XCTAssertEqual(f.model, "qwen3:8b")
            XCTAssertEqual(f.prompt, 20); XCTAssertEqual(f.completion, 5); XCTAssertEqual(f.cached, 8)
        }
    }

    func testSSEWithoutUsageHasNoCounts() {
        let sse = "data: {\"model\":\"m\",\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n"
        let f = scan(.sse, sse)
        XCTAssertFalse(f.hasCounts)
        XCTAssertEqual(f.model, "m")
    }

    func testAnthropicSSEAndResponsesAPI() {
        let anthropic = """
        event: message_start
        data: {"type":"message_start","message":{"model":"omlx-model","usage":{"input_tokens":30,"output_tokens":1,"cache_read_input_tokens":10}}}

        event: message_delta
        data: {"type":"message_delta","usage":{"output_tokens":42}}


        """
        let a = scan(.sse, anthropic)
        XCTAssertEqual(a.prompt, 40); XCTAssertEqual(a.cached, 10); XCTAssertEqual(a.completion, 42); XCTAssertEqual(a.model, "omlx-model")
        let responses = "data: {\"type\":\"response.created\",\"response\":{\"model\":\"r\",\"usage\":null}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"model\":\"r\",\"usage\":{\"input_tokens\":9,\"output_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":2},\"output_tokens_details\":{\"reasoning_tokens\":1}}}}\n\n"
        let r = scan(.sse, responses)
        XCTAssertEqual(r.prompt, 9); XCTAssertEqual(r.completion, 3); XCTAssertEqual(r.cached, 2); XCTAssertEqual(r.reasoning, 1)
    }

    func testOllamaNDJSONAndSingleObject() {
        let ndjson = """
        {"model":"llama3.2","created_at":"t","response":"Hel","done":false}
        {"model":"llama3.2","created_at":"t","response":"lo","done":false}
        {"model":"llama3.2","created_at":"t","response":"","done":true,"done_reason":"stop","total_duration":174560334,"load_duration":101397084,"prompt_eval_count":11,"prompt_eval_cached_count":8,"prompt_eval_duration":13074791,"eval_count":18,"eval_duration":52479709}
        """
        let f = scan(.ndjson, ndjson + "\n")
        XCTAssertEqual(f.prompt, 11); XCTAssertEqual(f.cached, 8); XCTAssertEqual(f.completion, 18)
        XCTAssertEqual(f.promptSeconds ?? 0, 0.013074791, accuracy: 1e-12)
        XCTAssertEqual(f.genSeconds ?? 0, 0.052479709, accuracy: 1e-12)
        XCTAssertEqual(f.totalSeconds ?? 0, 0.174560334, accuracy: 1e-12)
        XCTAssertEqual(scan(.ndjson, ndjson).completion, 18, "a last line without a newline still counts")
        let single = LocalJSONBody.fields(data(#"{"model":"m","message":{"role":"assistant","content":"x"},"done":true,"prompt_eval_count":5,"eval_count":6}"#))
        XCTAssertEqual(single.prompt, 5); XCTAssertEqual(single.completion, 6)
        XCTAssertTrue(LocalJSONBody.fields(data(#"{"model":"m","done":true,"done_reason":"load","response":""}"#)).isLoadOnly)
    }

    func testLMStudioStats() {
        let v0 = #"{"model":"qwen2.5-7b","usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60},"stats":{"tokens_per_second":25.0,"time_to_first_token":0.4,"generation_time":2.0,"stop_reason":"eosFound"}}"#
        let f = LocalJSONBody.fields(data(v0))
        XCTAssertEqual(f.prompt, 10); XCTAssertEqual(f.completion, 50)
        XCTAssertEqual(f.promptSeconds, 0.4); XCTAssertEqual(f.genSeconds, 2.0)
        let v1 = LocalJSONBody.fields(data(#"{"stats":{"input_tokens":100,"total_output_tokens":40,"reasoning_output_tokens":4,"tokens_per_second":20,"time_to_first_token_seconds":0.5}}"#))
        XCTAssertEqual(v1.prompt, 100); XCTAssertEqual(v1.completion, 40); XCTAssertEqual(v1.genSeconds ?? 0, 2, accuracy: 1e-9)
    }

    func testEmbeddingUsageHasOnlyPromptTokens() {
        let f = LocalJSONBody.fields(data(#"{"model":"e","data":[],"usage":{"prompt_tokens":12,"total_tokens":12}}"#))
        XCTAssertEqual(f.prompt, 12); XCTAssertNil(f.completion); XCTAssertTrue(f.hasCounts)
    }

    // MARK: Prometheus and pollers

    private let metrics = """
    # HELP llamacpp:prompt_tokens_total Number of prompt tokens processed.
    # TYPE llamacpp:prompt_tokens_total counter
    llamacpp:prompt_tokens_total 1000
    # TYPE llamacpp:prompt_seconds_total counter
    llamacpp:prompt_seconds_total 5.5
    llamacpp:tokens_predicted_total 400
    llamacpp:tokens_predicted_seconds_total 10
    llamacpp:requests_processing 0
    llamacpp:spec_decode_num_accepted_tokens_per_pos_total{position="0"} 3
    llamacpp:spec_decode_num_accepted_tokens_per_pos_total{position="1"} 2
    llamacpp:n_busy_slots_per_decode NaN
    """

    func testPrometheusParsing() {
        let samples = PrometheusText.samples(metrics)
        XCTAssertEqual(samples["llamacpp:prompt_tokens_total"], 1000)
        XCTAssertEqual(samples["llamacpp:spec_decode_num_accepted_tokens_per_pos_total"], 5)
        XCTAssertNil(samples["llamacpp:n_busy_slots_per_decode"])
        XCTAssertNotNil(LlamaMetricsReading(prometheus: metrics))
        XCTAssertNil(LlamaMetricsReading(prometheus: "process_cpu_seconds_total 3\n"), "another exporter is not llama.cpp")
    }

    func testLlamaCounterDiffBaselineDeltaAndRestart() {
        var differ = LlamaMetricsDiffer()
        let first = LlamaMetricsReading(promptTokens: 1000, promptSeconds: 5, predictedTokens: 400, predictedSeconds: 10)
        XCTAssertNil(differ.step(first, model: "m", now: 100), "the first reading is only a baseline")
        let second = LlamaMetricsReading(promptTokens: 1300, promptSeconds: 6.5, predictedTokens: 460, predictedSeconds: 12)
        let event = differ.step(second, model: "m", now: 160)
        XCTAssertEqual(event?.prompt, 300); XCTAssertEqual(event?.completion, 60)
        XCTAssertEqual(event?.promptSeconds ?? 0, 1.5, accuracy: 1e-9); XCTAssertEqual(event?.genSeconds ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(event?.requests, 0, "llama.cpp does not count requests")
        XCTAssertNil(differ.step(second, model: "m", now: 220), "no activity, no event")
        let restarted = LlamaMetricsReading(promptTokens: 50, promptSeconds: 0.3, predictedTokens: 10, predictedSeconds: 0.2)
        XCTAssertEqual(differ.step(restarted, model: "m", now: 280)?.prompt, 50, "a counter that went down counts from zero")
    }

    func testOMLXUsageShapesAndDiff() throws {
        let list = #"{"enabled":true,"range":"today","totals":{"requests":3,"prompt_tokens":300},"models":[{"model":"qwen3-8b-4bit","requests":3,"prompt_tokens":300,"completion_tokens":90,"cached_tokens":100,"prefill_seconds":2,"generation_seconds":3}],"heatmap":[]}"#
        let object = #"{"totals":{"requests":3},"models":{"qwen3-8b-4bit":{"requests":3,"prompt_tokens":300,"completion_tokens":90}}}"#
        let totalsOnly = #"{"totals":{"requests":2,"prompt_tokens":20,"completion_tokens":5},"heatmap":[]}"#
        XCTAssertEqual(OMLXUsageReading(json: data(list))?.models["qwen3-8b-4bit"]?.prompt, 300)
        XCTAssertEqual(OMLXUsageReading(json: data(object))?.models["qwen3-8b-4bit"]?.completion, 90)
        XCTAssertEqual(OMLXUsageReading(json: data(totalsOnly))?.models[""]?.requests, 2)
        XCTAssertNil(OMLXUsageReading(json: data("{\"detail\":\"nope\"}")))
        var differ = OMLXUsageDiffer()
        let a = try XCTUnwrap(OMLXUsageReading(json: data(list)))
        XCTAssertTrue(differ.step(a, now: 100).isEmpty)
        var b = a; b.models["qwen3-8b-4bit"] = OMLXUsageReading.Counters(requests: 5, prompt: 700, completion: 150, cached: 300, prefillSeconds: 4, generationSeconds: 6)
        let events = differ.step(b, now: 160)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].requests, 2); XCTAssertEqual(events[0].prompt, 400); XCTAssertEqual(events[0].cached, 200); XCTAssertEqual(events[0].completion, 60)
        XCTAssertEqual(events[0].model, "qwen3-8b-4bit"); XCTAssertEqual(events[0].backend, "omlx")
    }

    // MARK: HTTP framing

    func testStreamParserChunkedOneByteAtATime() {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/event-stream\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-T: 1\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n"
        let parser = HTTPStreamParser(role: .response)
        var heads: [Int] = [], body = Data(), ends = 0
        parser.onHead = { heads.append($0.status) }
        parser.onBody = { body.append($0) }
        parser.onMessageEnd = { ends += 1 }
        for byte in Array(raw.utf8) { parser.feed(Data([byte])) }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello world")
        XCTAssertEqual(heads, [200, 204]); XCTAssertEqual(ends, 2); XCTAssertFalse(parser.failed)
    }

    func testStreamParserRequestBodyAndGarbage() {
        let parser = HTTPStreamParser(role: .request)
        var targets: [String] = [], bodyBytes = 0
        parser.onHead = { targets.append($0.target) }
        parser.onBody = { bodyBytes += $0.count }
        parser.feed(data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcdGET /api/tags HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(targets, ["/v1/chat/completions", "/api/tags"]); XCTAssertEqual(bodyBytes, 4)
        let broken = HTTPStreamParser(role: .response)
        broken.feed(data("not http at all\r\n\r\n"))
        XCTAssertTrue(broken.failed)
    }

    func testInferencePaths() {
        XCTAssertTrue(LocalLLMPaths.isInference(method: "POST", target: "/v1/chat/completions"))
        XCTAssertTrue(LocalLLMPaths.isInference(method: "post", target: "/api/chat?x=1"))
        XCTAssertTrue(LocalLLMPaths.isInference(method: "POST", target: "/api/v0/chat/completions"))
        XCTAssertFalse(LocalLLMPaths.isInference(method: "GET", target: "/v1/models"))
        XCTAssertFalse(LocalLLMPaths.isInference(method: "POST", target: "/api/pull"))
    }

    // MARK: Cost, store, settings

    func testEquivalentCostOnReferenceModel() {
        let sonnet = LocalLLMReference.resolve("claude-sonnet-5-5")
        XCTAssertEqual(sonnet.input, 2); XCTAssertEqual(sonnet.output, 10)
        // 600k new prompt tokens at $2, 400k cached at $0.1, 100k output at $10 (per million).
        XCTAssertEqual(LocalLLMReport.cost(prompt: 1_000_000, cached: 400_000, completion: 100_000, price: sonnet), 2.24, accuracy: 1e-9)
        XCTAssertEqual(LocalLLMReference.resolve("no-such-model").id, LocalLLMReference.defaultModel, "an unknown id falls back to the default")
        let haiku = LocalLLMReference.resolve("claude-haiku-5-5")
        XCTAssertEqual(LocalLLMReport.cost(prompt: 1_000_000, cached: 0, completion: 1_000_000, price: haiku), 0.6, accuracy: 1e-9)
        let events = [LocalLLMEvent(id: "a", t: 1, backend: "ollama", via: "proxy", model: "qwen3:8b", prompt: 1_000_000, cached: 400_000, completion: 100_000)]
        XCTAssertEqual(LocalLLMReport(events: events).costUSD, 2.24, accuracy: 1e-9)
        XCTAssertEqual(LocalLLMReport(events: events, reference: "claude-haiku-5-5").reference.id, "claude-haiku-5-5")
    }

    func testReportSpeedsAreSumsOverSumsAndRequestsKnown() {
        let events = [
            LocalLLMEvent(id: "1", t: 1, backend: "ollama", via: "proxy", model: "m", prompt: 100, cached: 0, completion: 50, promptSeconds: 1, genSeconds: 2, seconds: 3, timing: "engine"),
            LocalLLMEvent(id: "2", t: 2, backend: "ollama", via: "proxy", model: "m", prompt: 300, cached: 100, completion: 150, promptSeconds: 1, genSeconds: 3, seconds: 4, timing: "engine"),
            LocalLLMEvent(id: "3", t: 3, backend: "ollama", via: "proxy", model: "m", unmetered: 1),
            LocalLLMEvent(id: "4", t: 4, backend: "llamacpp", via: "poll", model: "g", requests: 0, prompt: 10, completion: 5, genSeconds: 1, timing: "engine"),
        ]
        let report = LocalLLMReport(events: events)
        let ollama = report.lines.first { $0.backend == "ollama" }!
        XCTAssertEqual(ollama.requests, 3); XCTAssertEqual(ollama.unmetered, 1)
        XCTAssertEqual(ollama.promptTokensPerSecond ?? 0, (100.0 + 200.0) / 2, accuracy: 1e-9)
        XCTAssertEqual(ollama.generationTokensPerSecond ?? 0, 200.0 / 5, accuracy: 1e-9)
        XCTAssertEqual(ollama.activeSeconds, 7, accuracy: 1e-9)
        let llama = report.lines.first { $0.backend == "llamacpp" }!
        XCTAssertFalse(llama.requestsKnown)
        XCTAssertNil(llama.promptTokensPerSecond)
    }

    func testStoreAndLedgerBookLocalEventsOnceAsFreeLocalModels() {
        let event = LocalLLMEvent(id: "abc", t: 1_000_000, backend: "omlx", via: "poll", model: "qwen3-8b", requests: 4, prompt: 500, cached: 100, completion: 80)
        var store = UsageStatsStore()
        XCTAssertTrue(store.add(event.tokenEvent))
        XCTAssertFalse(store.add(event.tokenEvent), "the same event id is not counted twice")
        var ledger = AgentTokenLedger()
        XCTAssertTrue(ledger.add(event.tokenEvent)); XCTAssertFalse(ledger.add(event.tokenEvent))
        for input in [store.statsInput(since: 0, now: 2_000_000), ledger.statsInput(since: 0, now: 2_000_000)] {
            let report = UsageReport(input)
            XCTAssertEqual(report.calls, 4)
            XCTAssertEqual(report.total.total, 580)
            XCTAssertEqual(report.localTokens, 580)
            XCTAssertEqual(report.costUSD, 0)
            XCTAssertEqual(report.models.first?.status, .local)
            XCTAssertEqual(report.models.first?.provider, "local")
        }
        for backend in LocalLLMBackend.allCases {
            XCTAssertTrue(ModelIdentity.isLocal(LocalLLMEvent(id: "x", t: 1, backend: backend.rawValue, via: "proxy", model: "some-model").tokenEvent.model), backend.rawValue)
        }
    }

    func testAgentLogRuleSkipsLocalModelsOnlyWhileEnabled() {
        let local = AgentTokenEvent(provider: "claude", timestamp: 1, usage: TokenBreakdown(input: 1), dedupeKey: "k", model: "qwen3:8b")
        let cloud = AgentTokenEvent(provider: "claude", timestamp: 1, usage: TokenBreakdown(input: 1), dedupeKey: "k2", model: "claude-sonnet-5-5")
        var settings = LocalLLMSettings()
        XCTAssertFalse(LocalLLMIntegration.skipsAgentEvent(local, settings: settings))
        XCTAssertFalse(LocalLLMIntegration.skipsAgentEvent(local, settings: nil))
        settings.enabled = true
        XCTAssertTrue(LocalLLMIntegration.skipsAgentEvent(local, settings: settings))
        XCTAssertFalse(LocalLLMIntegration.skipsAgentEvent(cloud, settings: settings))
    }

    func testSettingsDefaultsPollingRuleAndValidation() throws {
        var settings = LocalLLMSettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(settings.polls(.llamacpp), "off by default")
        settings.enabled = true
        XCTAssertTrue(settings.polls(.llamacpp)); XCTAssertTrue(settings.polls(.omlx))
        XCTAssertFalse(settings.polls(.ollama), "Ollama has no usage of its own to poll")
        settings.update(.llamacpp) { $0.proxy = true }
        XCTAssertFalse(settings.polls(.llamacpp), "a proxied backend is not polled")
        XCTAssertEqual(settings.listenPort(.ollama), 11435); XCTAssertEqual(settings.proxyURL(.ollama), "http://127.0.0.1:11435")
        XCTAssertNil(settings.validate())
        settings.update(.llamacpp) { $0.listenPort = 9931 }
        XCTAssertNotNil(settings.validate(), "the proxy may not sit on its own upstream port")
        settings.update(.llamacpp) { $0.listenPort = 80 }
        XCTAssertNotNil(settings.validate())
        var all = WidgetSettings(); all.localModels = settings
        XCTAssertEqual(try JSONDecoder().decode(WidgetSettings.self, from: JSONEncoder().encode(all)).localLLM, settings)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WidgetSettings())) as? [String: Any])
        json["localLLM"] = nil
        XCTAssertNil(try JSONDecoder().decode(WidgetSettings.self, from: JSONSerialization.data(withJSONObject: json)).localLLM, "settings saved before this feature still load")
    }

    func testLogAppendReadTailAndCompaction() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = LocalLLMLog(url: url)
        let now = 10_000_000.0
        let recent = LocalLLMEvent(id: "r", t: now - 100, backend: "ollama", via: "proxy", model: "m", prompt: 10, completion: 5)
        log.append([recent])
        let first = log.readNew(from: 0)
        XCTAssertEqual(first.events, [recent])
        let next = LocalLLMEvent(id: "n", t: now - 50, backend: "ollama", via: "proxy", model: "m", prompt: 1, completion: 1)
        log.append([next])
        XCTAssertEqual(log.readNew(from: first.offset).events, [next], "tailing reads only what was appended")
        // Two old events of one hour merge; one past retention disappears.
        let old1 = LocalLLMEvent(id: "o1", t: now - 5 * 86400, backend: "ollama", via: "proxy", model: "m", requests: 1, prompt: 10, completion: 5, seconds: 1)
        let old2 = LocalLLMEvent(id: "o2", t: now - 5 * 86400 + 60, backend: "ollama", via: "proxy", model: "m", requests: 1, prompt: 20, completion: 7, seconds: 2)
        let ancient = LocalLLMEvent(id: "a", t: now - 40 * 86400, backend: "ollama", via: "proxy", model: "m", prompt: 99)
        log.append([old1, old2, ancient])
        log.compact(now: now)
        let all = log.events()
        XCTAssertFalse(all.contains { $0.id == "a" })
        let merged = try XCTUnwrap(all.first { $0.id.hasPrefix("hour|") })
        XCTAssertEqual(merged.requests, 2); XCTAssertEqual(merged.prompt, 30); XCTAssertEqual(merged.completion, 12); XCTAssertEqual(merged.seconds, 3)
        XCTAssertEqual(all.count, 3)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "the event file is private")
    }

    func testLocalizationCompleteInAllLanguages() {
        for language in WidgetLanguage.allCases where language != .system {
            for key in localTranslations.keys {
                XCTAssertFalse(localTranslations[key]?[language.rawValue, default: ""].isEmpty ?? true, "\(language.rawValue): \(key)")
            }
        }
        for (key, translations) in localTranslations {
            let placeholders = translations["en"]!.components(separatedBy: "%@").count
            for (code, text) in translations { XCTAssertEqual(text.components(separatedBy: "%@").count, placeholders, "\(code): \(key)") }
        }
    }

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

    // MARK: Proxy (fake local server, real sockets)

    private func post(_ path: String, body: String = "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"PRIVATE PROMPT\"}]}") -> Data {
        Data("POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }
    private func chunked(_ text: String, pieces: Int = 3) -> [Data] {
        let bytes = Array(text.utf8)
        let size = max(1, bytes.count / pieces)
        var result: [Data] = []
        var index = 0
        while index < bytes.count {
            let part = Array(bytes[index..<min(bytes.count, index + size)])
            result.append(Data((String(part.count, radix: 16) + "\r\n").utf8) + Data(part) + Data("\r\n".utf8))
            index += size
        }
        return result
    }

    private func startProxy(upstream: FakeServer, backend: LocalLLMBackend = .ollama) throws -> (LocalMeteringProxy, EventCollector) {
        let collector = EventCollector()
        let proxy = LocalMeteringProxy(backend: backend, listenPort: 0, upstreamPort: upstream.port) { collector.add($0) }
        try proxy.start()
        XCTAssertGreaterThan(proxy.port, 0)
        return (proxy, collector)
    }

    func testProxyPassesContentLengthResponseUnchangedAndMetersIt() throws {
        let body = #"{"model":"llama3","choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}"#
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nX-Custom: kept\r\n\r\n\(body)".utf8)
        let server = try FakeServer { _, _ in .init(slices: [response]) }
        defer { server.shutdown() }
        let (proxy, collector) = try startProxy(upstream: server)
        defer { proxy.stop() }
        let request = post("/v1/chat/completions")
        let received = exchange(port: proxy.port, request: request, expected: response.count)
        XCTAssertEqual(received, response, "response bytes are identical")
        XCTAssertEqual(server.requests.first?.body, request.suffix(from: request.firstRange(of: Data("\r\n\r\n".utf8))!.upperBound), "request body is identical")
        let events = collector.wait(count: 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.prompt, 12); XCTAssertEqual(events.first?.completion, 3); XCTAssertEqual(events.first?.via, "proxy")
        XCTAssertEqual(events.first?.model, "llama3"); XCTAssertEqual(events.first?.backend, "ollama"); XCTAssertEqual(events.first?.requests, 1)
    }

    func testProxyPassesChunkedSSEByteForByteEvenWhenDeliveredOneByteAtATime() throws {
        let sse = "data: {\"model\":\"qwen3:8b\",\"choices\":[{\"delta\":{\"content\":\"a\"}}],\"usage\":null}\n\ndata: {\"model\":\"qwen3:8b\",\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":5,\"total_tokens\":25}}\n\ndata: [DONE]\n\n"
        let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nCache-Control: no-cache\r\n\r\n".utf8)
        let chunks = chunked(sse, pieces: 4) + [Data("0\r\n\r\n".utf8)]
        let whole = chunks.reduce(head) { $0 + $1 }
        for slicing in [false, true] {
            let slices: [Data] = slicing ? whole.map { Data([$0]) } : [head] + chunks
            let server = try FakeServer { _, _ in .init(slices: slices) }
            defer { server.shutdown() }
            let (proxy, collector) = try startProxy(upstream: server)
            defer { proxy.stop() }
            let received = exchange(port: proxy.port, request: post("/v1/chat/completions"), expected: whole.count)
            XCTAssertEqual(received, whole, slicing ? "one byte at a time" : "chunk by chunk")
            let events = collector.wait(count: 1)
            XCTAssertEqual(events.first?.prompt, 20); XCTAssertEqual(events.first?.completion, 5); XCTAssertEqual(events.first?.model, "qwen3:8b")
            XCTAssertEqual(events.first?.unmetered, 0)
        }
    }

    func testProxyOllamaNDJSONStreamAndEngineTimings() throws {
        let lines = "{\"model\":\"llama3.2\",\"response\":\"a\",\"done\":false}\n{\"model\":\"llama3.2\",\"response\":\"\",\"done\":true,\"total_duration\":2000000000,\"prompt_eval_count\":11,\"prompt_eval_duration\":500000000,\"eval_count\":18,\"eval_duration\":1500000000}\n"
        let head = Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let chunks = chunked(lines, pieces: 2) + [Data("0\r\n\r\n".utf8)]
        let whole = chunks.reduce(head) { $0 + $1 }
        let server = try FakeServer { _, _ in .init(slices: [head] + chunks) }
        defer { server.shutdown() }
        let (proxy, collector) = try startProxy(upstream: server)
        defer { proxy.stop() }
        XCTAssertEqual(exchange(port: proxy.port, request: post("/api/generate"), expected: whole.count), whole)
        let event = try XCTUnwrap(collector.wait(count: 1).first)
        XCTAssertEqual(event.prompt, 11); XCTAssertEqual(event.completion, 18); XCTAssertEqual(event.timing, "engine")
        XCTAssertEqual(event.promptSeconds ?? 0, 0.5, accuracy: 1e-9); XCTAssertEqual(event.genSeconds ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(event.seconds ?? 0, 2.0, accuracy: 1e-9)
    }

    func testProxyCountsStreamWithoutUsageAsUnmeteredAndGuessesNothing() throws {
        let sse = "data: {\"model\":\"m\",\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n"
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(sse.utf8.count)\r\n\r\n\(sse)".utf8)
        let server = try FakeServer { _, _ in .init(slices: [response]) }
        defer { server.shutdown() }
        let (proxy, collector) = try startProxy(upstream: server)
        defer { proxy.stop() }
        XCTAssertEqual(exchange(port: proxy.port, request: post("/v1/chat/completions"), expected: response.count), response)
        let event = try XCTUnwrap(collector.wait(count: 1).first)
        XCTAssertEqual(event.requests, 1); XCTAssertEqual(event.unmetered, 1); XCTAssertEqual(event.prompt, 0); XCTAssertEqual(event.completion, 0)
    }

    func testProxyKeepAliveTwoRequestsAndIgnoresNonInferencePaths() throws {
        let body = #"{"model":"m","usage":{"prompt_tokens":4,"completion_tokens":2}}"#
        let chat = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        let tags = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let server = try FakeServer { _, target in .init(slices: [target == "/api/tags" ? tags : chat]) }
        defer { server.shutdown() }
        let (proxy, collector) = try startProxy(upstream: server)
        defer { proxy.stop() }
        let list = Data("GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        let received = exchange(port: proxy.port, steps: [(list, tags.count), (post("/v1/chat/completions"), chat.count), (post("/v1/chat/completions"), chat.count)])
        XCTAssertEqual(received, tags + chat + chat)
        let events = collector.wait(count: 2)
        XCTAssertEqual(events.count, 2, "the listing is not a model call")
        XCTAssertEqual(events.reduce(0) { $0 + $1.prompt }, 8)
    }

    func testProxyDerivesTimingsFromStreamWhenServerGivesNone() throws {
        let first = "data: {\"model\":\"m\",\"choices\":[{\"delta\":{\"content\":\"a\"}}],\"usage\":null}\n\n"
        let last = "data: {\"model\":\"m\",\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":10}}\n\ndata: [DONE]\n\n"
        let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let c1 = chunked(first, pieces: 1)[0], c2 = chunked(last, pieces: 1)[0], end = Data("0\r\n\r\n".utf8)
        let server = try FakeServer { _, _ in .init(slices: [head, c1, c2, end], pause: 0.15) }
        defer { server.shutdown() }
        let (proxy, collector) = try startProxy(upstream: server)
        defer { proxy.stop() }
        _ = exchange(port: proxy.port, request: post("/v1/chat/completions"), expected: head.count + c1.count + c2.count + end.count)
        let event = try XCTUnwrap(collector.wait(count: 1).first)
        XCTAssertEqual(event.timing, "proxy")
        XCTAssertGreaterThan(event.genSeconds ?? 0, 0.05)
        XCTAssertLessThan(event.genSeconds ?? 99, 2)
    }

    func testProxyMetersStrataAnthropicStream() throws {
        let sse = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"strata-moe\",\"usage\":{\"input_tokens\":25,\"output_tokens\":1}}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hi\"}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":12}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let chunks = chunked(sse, pieces: 5) + [Data("0\r\n\r\n".utf8)]
        let whole = chunks.reduce(head) { $0 + $1 }
        let server = try FakeServer { _, _ in .init(slices: [head] + chunks) }
        defer { server.shutdown() }
        let (proxy, collector) = try startProxy(upstream: server, backend: .strata)
        defer { proxy.stop() }
        XCTAssertEqual(exchange(port: proxy.port, request: post("/v1/messages"), expected: whole.count), whole)
        let event = try XCTUnwrap(collector.wait(count: 1).first)
        XCTAssertEqual(event.backend, "strata"); XCTAssertEqual(event.prompt, 25); XCTAssertEqual(event.completion, 12); XCTAssertEqual(event.model, "strata-moe")
        let plain = LocalJSONBody.fields(data(#"{"type":"message","model":"strata-moe","usage":{"input_tokens":7,"output_tokens":9}}"#))
        XCTAssertEqual(plain.prompt, 7); XCTAssertEqual(plain.completion, 9)
        XCTAssertFalse(LocalLLMBackend.strata.hasPoller)
        XCTAssertEqual(Set(LocalLLMBackend.allCases.map(\.defaultProxyPort)).count, LocalLLMBackend.allCases.count, "default proxy ports are distinct")
    }

    func testProxyDoesNotAcceptPrivilegedPorts() {
        let proxy = LocalMeteringProxy(backend: .ollama, listenPort: 80, upstreamPort: 11434) { _ in }
        XCTAssertThrowsError(try proxy.start())
    }

    func testProxyAnswers502WhenUpstreamIsDown() throws {
        let server = try FakeServer { _, _ in .init(slices: []) }
        let dead = server.port
        server.shutdown()
        Thread.sleep(forTimeInterval: 0.4)
        let proxy = LocalMeteringProxy(backend: .ollama, listenPort: 0, upstreamPort: dead) { _ in }
        try proxy.start()
        defer { proxy.stop() }
        let reply = exchange(port: proxy.port, request: post("/api/chat"), expected: 20)
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 502"))
    }

    // MARK: Pollers against fake servers

    func testServicePollsLlamaCppMetricsAndSkipsWhenProxied() throws {
        var current = metrics
        let server = try FakeServer { _, target in
            let body = target == "/metrics" ? current : #"{"data":[{"id":"gguf-model"}]}"#
            return .init(slices: [Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)], closeAfter: true)
        }
        defer { server.shutdown() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = LocalLLMService(log: LocalLLMLog(url: url), llamaPorts: [server.port])
        var settings = LocalLLMSettings(); settings.enabled = true
        service.apply(settings)
        XCTAssertTrue(service.pollOnce(now: 100).isEmpty, "baseline")
        XCTAssertEqual(service.pollState(.llamacpp), .ok(port: server.port))
        current = metrics.replacingOccurrences(of: "llamacpp:prompt_tokens_total 1000", with: "llamacpp:prompt_tokens_total 1250")
            .replacingOccurrences(of: "llamacpp:tokens_predicted_total 400", with: "llamacpp:tokens_predicted_total 470")
        let events = service.pollOnce(now: 160)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.prompt, 250); XCTAssertEqual(events.first?.completion, 70); XCTAssertEqual(events.first?.model, "gguf-model")
        XCTAssertEqual(LocalLLMLog(url: url).events().count, 1, "events are written to the log")
        settings.update(.llamacpp) { $0.proxy = true; $0.listenPort = 0 }
        XCTAssertFalse(settings.polls(.llamacpp))
        service.apply(LocalLLMSettings())
        XCTAssertTrue(service.pollOnce(now: 220).isEmpty, "nothing runs while the feature is off")
        XCTAssertEqual(service.pollState(.llamacpp), .off)
    }

    func testServiceReportsLlamaWithoutMetricsAndOMLXNeedsKey() throws {
        let plain = try FakeServer { _, _ in .init(slices: [Data("HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)], closeAfter: true) }
        let guarded = try FakeServer { _, _ in .init(slices: [Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)], closeAfter: true) }
        defer { plain.shutdown(); guarded.shutdown() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = LocalLLMService(log: LocalLLMLog(url: url), omlxKey: { nil }, llamaPorts: [plain.port], omlxPort: guarded.port)
        var settings = LocalLLMSettings(); settings.enabled = true
        service.apply(settings)
        service.pollOnce(now: 1)
        XCTAssertEqual(service.pollState(.llamacpp), .metricsUnavailable)
        XCTAssertEqual(service.pollState(.omlx), .needsKey)
    }

    func testServiceSendsOMLXKeyAndDiffsUsage() throws {
        var total = 3
        let server = try FakeServer { _, _ in
            let body = #"{"enabled":true,"totals":{"requests":\#(total)},"models":[{"model":"m1","requests":\#(total),"prompt_tokens":\#(total * 100),"completion_tokens":\#(total * 10)}]}"#
            return .init(slices: [Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)], closeAfter: true)
        }
        defer { server.shutdown() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = LocalLLMService(log: LocalLLMLog(url: url), omlxKey: { "secret-key" }, llamaPorts: [], omlxPort: server.port)
        var settings = LocalLLMSettings(); settings.enabled = true
        service.apply(settings)
        XCTAssertTrue(service.pollOnce(now: 10).isEmpty)
        total = 5
        let events = service.pollOnce(now: 70)
        XCTAssertEqual(events.first?.requests, 2); XCTAssertEqual(events.first?.prompt, 200); XCTAssertEqual(events.first?.model, "m1")
        XCTAssertEqual(server.requests.last?.headers["authorization"], "Bearer secret-key")
        XCTAssertEqual(service.pollState(.omlx), .ok(port: server.port))
    }

    func testServiceStartsProxyOnlyForEnabledBackendsAndStopsIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = LocalLLMService(log: LocalLLMLog(url: url))
        var settings = LocalLLMSettings(); settings.enabled = true
        service.apply(settings)
        XCTAssertFalse(service.proxyRunning(.ollama), "proxies are off by default")
        settings.update(.ollama) { $0.proxy = true; $0.listenPort = 0 }
        service.apply(settings)
        XCTAssertTrue(service.proxyRunning(.ollama))
        settings.enabled = false
        service.apply(settings)
        XCTAssertFalse(service.proxyRunning(.ollama))
        service.stop()
    }

    #endif
}
