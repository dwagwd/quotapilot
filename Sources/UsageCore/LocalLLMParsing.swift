import Foundation

// Extracts usage and timing fields from local-server responses. Text is parsed and discarded; only numbers and
// the model id are kept. See docs/local-llm.md.

/// Counts and timings found in one response (or in the stream of one response).
public struct LocalUsageFields: Equatable {
    public var model: String?
    /// Prompt tokens including cached ones; nil when the response gave no prompt count.
    public var prompt: Double?
    public var cached: Double = 0
    public var completion: Double?
    public var reasoning: Double = 0
    public var promptSeconds: Double?
    public var genSeconds: Double?
    /// The server's own total time for the request.
    public var totalSeconds: Double?
    /// Set when `promptSeconds` / `genSeconds` came from the server.
    public var engineTimings = false
    /// Ollama `done_reason` of a model load or unload (no inference).
    public var isLoadOnly = false
    public var hasCounts: Bool { prompt != nil || completion != nil }
    public init() {}
}

/// Merges every JSON object of a response. OpenAI `usage`, Anthropic `message.usage` / `usage`, Responses API `response.usage`,
/// llama.cpp `timings`, Ollama's final object and LM Studio's `stats` are recognised. Counts take the largest value seen,
/// because streams report them more than once (Anthropic repeats `output_tokens` in `message_delta`).
public struct LocalUsageAccumulator {
    public private(set) var fields = LocalUsageFields()
    public init() {}

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isFinite && double >= 0 ? double : nil
    }
    private mutating func raise(_ keyPath: WritableKeyPath<LocalUsageFields, Double?>, _ value: Double?) {
        guard let value else { return }
        fields[keyPath: keyPath] = max(fields[keyPath: keyPath] ?? 0, value)
    }

    public mutating func ingest(_ object: [String: Any]) {
        if fields.model == nil, let model = (object["model"] as? String) ?? ((object["response"] as? [String: Any])?["model"] as? String)
            ?? ((object["message"] as? [String: Any])?["model"] as? String), !model.isEmpty { fields.model = String(model.prefix(160)) }
        for container in [object, object["response"] as? [String: Any], object["message"] as? [String: Any]].compactMap({ $0 }) {
            if let usage = container["usage"] as? [String: Any] { ingestUsage(usage) }
        }
        if let timings = object["timings"] as? [String: Any] { ingestTimings(timings) }
        if let stats = object["stats"] as? [String: Any] { ingestStats(stats) }
        if object["eval_count"] != nil || object["prompt_eval_count"] != nil || object["total_duration"] != nil { ingestOllama(object) }
        if let reason = object["done_reason"] as? String, reason == "load" || reason == "unload", object["eval_count"] == nil { fields.isLoadOnly = true }
    }

    private mutating func ingestUsage(_ usage: [String: Any]) {
        let hasOpenAIPrompt = usage["prompt_tokens"] != nil
        var prompt = Self.number(usage["prompt_tokens"]) ?? Self.number(usage["input_tokens"])
        let completion = Self.number(usage["completion_tokens"]) ?? Self.number(usage["output_tokens"])
        var cached = Self.number((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])
            ?? Self.number((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"])
        if cached == nil, let read = Self.number(usage["cache_read_input_tokens"]) {
            // Anthropic style: input_tokens excludes cache reads.
            cached = read
            if !hasOpenAIPrompt, let value = prompt { prompt = value + read + (Self.number(usage["cache_creation_input_tokens"]) ?? 0) }
        }
        raise(\.prompt, prompt); raise(\.completion, completion)
        if let cached { fields.cached = max(fields.cached, cached) }
        let reasoning = Self.number((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"])
            ?? Self.number((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"])
        if let reasoning { fields.reasoning = max(fields.reasoning, reasoning) }
    }

    /// llama.cpp: prompt_n counts only the tokens processed; cache_n the ones reused from the cache.
    private mutating func ingestTimings(_ timings: [String: Any]) {
        let processed = Self.number(timings["prompt_n"]), cache = Self.number(timings["cache_n"]) ?? 0
        if let processed {
            raise(\.prompt, processed + cache)
            fields.cached = max(fields.cached, cache)
        }
        raise(\.completion, Self.number(timings["predicted_n"]))
        if let ms = Self.number(timings["prompt_ms"]) { fields.promptSeconds = ms / 1000; fields.engineTimings = true }
        if let ms = Self.number(timings["predicted_ms"]) { fields.genSeconds = ms / 1000; fields.engineTimings = true }
    }

    /// Ollama durations are nanoseconds.
    private mutating func ingestOllama(_ object: [String: Any]) {
        raise(\.prompt, Self.number(object["prompt_eval_count"]))
        raise(\.completion, Self.number(object["eval_count"]))
        if let cached = Self.number(object["prompt_eval_cached_count"]) { fields.cached = max(fields.cached, cached) }
        if let ns = Self.number(object["prompt_eval_duration"]) { fields.promptSeconds = ns / 1e9; fields.engineTimings = true }
        if let ns = Self.number(object["eval_duration"]) { fields.genSeconds = ns / 1e9; fields.engineTimings = true }
        if let ns = Self.number(object["total_duration"]) { fields.totalSeconds = ns / 1e9 }
    }

    /// LM Studio: `/api/v0` has tokens_per_second, time_to_first_token and generation_time (seconds); the native
    /// `/api/v1/chat` has input_tokens, total_output_tokens, tokens_per_second and time_to_first_token_seconds.
    private mutating func ingestStats(_ stats: [String: Any]) {
        raise(\.prompt, Self.number(stats["input_tokens"]))
        raise(\.completion, Self.number(stats["total_output_tokens"]))
        if let reasoning = Self.number(stats["reasoning_output_tokens"]) { fields.reasoning = max(fields.reasoning, reasoning) }
        let first = Self.number(stats["time_to_first_token"]) ?? Self.number(stats["time_to_first_token_seconds"])
        if let first { fields.promptSeconds = first; fields.engineTimings = true }
        if let time = Self.number(stats["generation_time"]) { fields.genSeconds = time; fields.engineTimings = true }
        else if let speed = Self.number(stats["tokens_per_second"]), speed > 0, let tokens = Self.number(stats["total_output_tokens"]) {
            fields.genSeconds = tokens / speed; fields.engineTimings = true
        }
    }
}

/// Reads JSON text lines (SSE `data:` lines or NDJSON) without keeping them. Chunks of a stream usually carry no counts,
/// so a line is parsed only when it can: it mentions usage, timings, stats or Ollama counts, or the model is still unknown.
public struct LocalLineScanner {
    public enum Kind { case sse, ndjson }
    public let kind: Kind
    public private(set) var accumulator = LocalUsageAccumulator()
    private var buffer = Data()
    private var modelTries = 0
    private static let maxLine = 8 * 1_048_576

    public init(kind: Kind) { self.kind = kind }

    public mutating func feed(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            handle(line)
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > Self.maxLine { buffer.removeAll() }
    }

    /// Call once the body ended: a last line without a newline still counts.
    public mutating func finish() {
        if !buffer.isEmpty { handle(buffer[...]); buffer.removeAll() }
    }

    private mutating func handle(_ rawLine: Data.SubSequence) {
        var line = rawLine
        if line.last == 0x0D { line = line.dropLast() }
        if kind == .sse {
            guard line.starts(with: Array("data:".utf8)) else { return }
            line = line.dropFirst(5)
            if line.first == 0x20 { line = line.dropFirst() }
        }
        guard !line.isEmpty, line.first == UInt8(ascii: "{") else { return }
        let text = String(decoding: line, as: UTF8.self)
        let usefulKey = text.hasBytes("\"timings\"") || text.hasBytes("\"stats\"") || text.hasBytes("\"eval_count\"")
            || text.hasBytes("\"prompt_eval_count\"") || text.hasBytes("\"total_duration\"")
            || (text.hasBytes("\"usage\"") && !text.hasBytes("\"usage\":null") && !text.hasBytes("\"usage\": null"))
        let needsModel = accumulator.fields.model == nil && modelTries < 3
        guard usefulKey || needsModel else { return }
        if needsModel { modelTries += 1 }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        accumulator.ingest(object)
    }
}

/// Fields of a whole JSON response body (non-streaming).
public enum LocalJSONBody {
    public static func fields(_ body: Data) -> LocalUsageFields {
        var accumulator = LocalUsageAccumulator()
        if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] { accumulator.ingest(object) }
        return accumulator.fields
    }
}

// MARK: Prometheus text

public enum PrometheusText {
    /// Sample values by metric name; samples of one name with different labels are added up.
    /// Comments, `NaN` and `Inf` values are skipped.
    public static func samples(_ text: String) -> [String: Double] {
        var result: [String: Double] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let name: String, rest: Substring
            if let brace = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"), brace < close {
                name = String(line[..<brace]); rest = line[line.index(after: close)...]
            } else if let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                name = String(line[..<space]); rest = line[space...]
            } else { continue }
            guard let token = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, let value = Double(token), value.isFinite else { continue }
            result[name, default: 0] += value
        }
        return result
    }
}

/// The four llama.cpp counters that matter (`--metrics`).
public struct LlamaMetricsReading: Equatable {
    public var promptTokens: Double
    public var promptSeconds: Double
    public var predictedTokens: Double
    public var predictedSeconds: Double

    public init(promptTokens: Double, promptSeconds: Double, predictedTokens: Double, predictedSeconds: Double) {
        self.promptTokens = promptTokens; self.promptSeconds = promptSeconds
        self.predictedTokens = predictedTokens; self.predictedSeconds = predictedSeconds
    }

    /// nil when the text is not a llama.cpp metrics page.
    public init?(prometheus text: String) {
        let samples = PrometheusText.samples(text)
        guard let prompt = samples["llamacpp:prompt_tokens_total"], let predicted = samples["llamacpp:tokens_predicted_total"] else { return nil }
        self.init(promptTokens: prompt, promptSeconds: samples["llamacpp:prompt_seconds_total"] ?? 0,
                  predictedTokens: predicted, predictedSeconds: samples["llamacpp:tokens_predicted_seconds_total"] ?? 0)
    }
}

/// Differences of cumulative counters between polls. The first reading only sets the baseline; a value that went down means the
/// server restarted (or the day rolled over), so the new value counts from zero.
public struct CounterDiff {
    private var last: [String: Double] = [:]
    public init() {}
    public mutating func delta(_ key: String, _ value: Double) -> Double? {
        defer { last[key] = value }
        guard let previous = last[key] else { return nil }
        return value >= previous ? value - previous : value
    }
    public mutating func reset() { last = [:] }
}

public struct LlamaMetricsDiffer {
    private var counters = CounterDiff()
    public init() {}

    /// Event for what the server did since the previous reading; nil for the first reading and when nothing happened.
    public mutating func step(_ reading: LlamaMetricsReading, model: String?, now: Double) -> LocalLLMEvent? {
        let prompt = counters.delta("pt", reading.promptTokens), promptSeconds = counters.delta("ps", reading.promptSeconds)
        let predicted = counters.delta("gt", reading.predictedTokens), genSeconds = counters.delta("gs", reading.predictedSeconds)
        guard let prompt, let predicted, prompt > 0 || predicted > 0 else { return nil }
        // prompt_tokens_total counts tokens processed, so cache reuse is not part of it and nothing is cached here.
        return LocalLLMEvent(id: "poll|llamacpp|\(model ?? "")|\(Int(now))", t: now, backend: "llamacpp", via: "poll", model: model,
                             requests: 0, prompt: prompt, completion: predicted,
                             promptSeconds: prompt > 0 ? promptSeconds : nil, genSeconds: predicted > 0 ? genSeconds : nil,
                             seconds: (promptSeconds ?? 0) + (genSeconds ?? 0), timing: "engine")
    }
}

// MARK: oMLX

/// `GET /admin/api/usage?range=today` of oMLX. The documented fields are `totals`, `models` and `heatmap` with
/// requests, prompt_tokens, completion_tokens, cached_tokens, prefill_seconds and generation_seconds. The shape of `models`
/// is not documented: a list of objects (with `model`, `model_id` or `id`) and an object keyed by model id are both accepted.
public struct OMLXUsageReading: Equatable {
    public struct Counters: Equatable {
        public var requests = 0.0, prompt = 0.0, completion = 0.0, cached = 0.0, prefillSeconds = 0.0, generationSeconds = 0.0
        public init(requests: Double = 0, prompt: Double = 0, completion: Double = 0, cached: Double = 0, prefillSeconds: Double = 0, generationSeconds: Double = 0) {
            self.requests = requests; self.prompt = prompt; self.completion = completion; self.cached = cached
            self.prefillSeconds = prefillSeconds; self.generationSeconds = generationSeconds
        }
        var hasData: Bool { requests > 0 || prompt > 0 || completion > 0 }
    }
    /// Counters per canonical model id; "" holds totals that have no model split.
    public var models: [String: Counters]

    public init(models: [String: Counters]) { self.models = models }

    public init?(json: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        if root["enabled"] as? Bool == false { self.init(models: [:]); return }
        func counters(_ object: [String: Any]) -> Counters {
            func n(_ key: String) -> Double { (object[key] as? NSNumber)?.doubleValue ?? 0 }
            return Counters(requests: n("requests"), prompt: n("prompt_tokens"), completion: n("completion_tokens"), cached: n("cached_tokens"),
                            prefillSeconds: n("prefill_seconds"), generationSeconds: n("generation_seconds"))
        }
        var result: [String: Counters] = [:]
        if let list = root["models"] as? [[String: Any]] {
            for item in list {
                guard let id = (item["model"] as? String) ?? (item["model_id"] as? String) ?? (item["id"] as? String) ?? (item["name"] as? String) else { continue }
                result[id] = counters(item)
            }
        } else if let table = root["models"] as? [String: Any] {
            for (id, value) in table { if let item = value as? [String: Any] { result[id] = counters(item) } }
        }
        if result.isEmpty, let totals = root["totals"] as? [String: Any] {
            let value = counters(totals)
            if value.hasData { result[""] = value }
        }
        guard root["totals"] != nil || root["models"] != nil else { return nil }
        self.init(models: result)
    }
}

public struct OMLXUsageDiffer {
    private var counters = CounterDiff()
    public init() {}

    public mutating func step(_ reading: OMLXUsageReading, now: Double) -> [LocalLLMEvent] {
        var events: [LocalLLMEvent] = []
        for (id, value) in reading.models.sorted(by: { $0.key < $1.key }) {
            let requests = counters.delta(id + "|r", value.requests), prompt = counters.delta(id + "|p", value.prompt)
            let completion = counters.delta(id + "|c", value.completion), cached = counters.delta(id + "|k", value.cached)
            let prefill = counters.delta(id + "|ps", value.prefillSeconds), generation = counters.delta(id + "|gs", value.generationSeconds)
            guard let requests, let prompt, let completion, requests > 0 || prompt > 0 || completion > 0 else { continue }
            events.append(LocalLLMEvent(id: "poll|omlx|\(id)|\(Int(now))", t: now, backend: "omlx", via: "poll", model: id.isEmpty ? nil : id,
                                        requests: Int(requests.rounded()), prompt: prompt, cached: min(cached ?? 0, prompt), completion: completion,
                                        promptSeconds: (prefill ?? 0) > 0 ? prefill : nil, genSeconds: (generation ?? 0) > 0 ? generation : nil,
                                        seconds: (prefill ?? 0) + (generation ?? 0), timing: "engine"))
        }
        return events
    }
}
