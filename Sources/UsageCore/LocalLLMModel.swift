import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Local model usage (Ollama, LM Studio, llama.cpp, oMLX and other OpenAI-compatible servers). See docs/local-llm.md.
// Only counts, model ids and timings are kept: never prompts or outputs.

public enum LocalLLMBackend: String, Codable, CaseIterable {
    case ollama, lmstudio, llamacpp, omlx, strata
    /// Any other OpenAI-compatible local server reached through the metering proxy.
    case custom

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .llamacpp: return "llama.cpp"
        case .omlx: return "oMLX"
        case .strata: return "Strata"
        case .custom: return "Other"
        }
    }
    public var defaultUpstreamPort: Int {
        switch self {
        case .ollama: return 11434
        case .lmstudio: return 1234
        case .llamacpp: return 9931
        case .omlx: return 8000
        case .strata: return 8080
        case .custom: return 8090
        }
    }
    /// Ports probed by the poller, the documented default first. llama.cpp used 8080 before its README changed to 9931.
    public var pollPorts: [Int] { self == .llamacpp ? [9931, 8080] : [defaultUpstreamPort] }
    public var defaultProxyPort: Int { defaultUpstreamPort + 1 }
    /// Backends whose own server reports usage a poller can read without a proxy.
    public var hasPoller: Bool { self == .llamacpp || self == .omlx }
}

public struct LocalLLMBackendConfig: Codable, Equatable {
    /// Metering proxy for this backend (off by default).
    public var proxy: Bool? = nil
    public var listenPort: Int? = nil
    public var upstreamHost: String? = nil
    public var upstreamPort: Int? = nil
    public init() {}
}

public struct LocalLLMSettings: Codable, Equatable {
    /// Master switch: pollers and proxies run only when on (off by default).
    public var enabled: Bool? = nil
    /// Price-table id of the cloud model that the equivalent cost is computed on.
    public var referenceModel: String? = nil
    public var backends: [String: LocalLLMBackendConfig]? = nil
    public init() {}

    public var isEnabled: Bool { enabled ?? false }
    public func config(_ backend: LocalLLMBackend) -> LocalLLMBackendConfig { backends?[backend.rawValue] ?? LocalLLMBackendConfig() }
    public mutating func update(_ backend: LocalLLMBackend, _ change: (inout LocalLLMBackendConfig) -> Void) {
        var all = backends ?? [:]
        var config = all[backend.rawValue] ?? LocalLLMBackendConfig()
        change(&config)
        all[backend.rawValue] = config
        backends = all
    }
    public func proxyEnabled(_ backend: LocalLLMBackend) -> Bool { config(backend).proxy ?? false }
    public func listenPort(_ backend: LocalLLMBackend) -> Int { config(backend).listenPort ?? backend.defaultProxyPort }
    public func upstreamHost(_ backend: LocalLLMBackend) -> String {
        let host = config(backend).upstreamHost?.trimmingCharacters(in: .whitespaces) ?? ""
        return host.isEmpty ? "127.0.0.1" : host
    }
    public func upstreamPort(_ backend: LocalLLMBackend) -> Int { config(backend).upstreamPort ?? backend.defaultUpstreamPort }
    /// URL a client should use instead of the server's own address.
    public func proxyURL(_ backend: LocalLLMBackend) -> String { "http://127.0.0.1:\(listenPort(backend))" }
    /// A backend with its proxy on is not polled: the proxy sees the same requests (docs/local-llm.md, "Avoiding double counting").
    public func polls(_ backend: LocalLLMBackend) -> Bool { isEnabled && backend.hasPoller && !proxyEnabled(backend) }
    /// Ports are valid when a user can bind them without privileges and the proxy does not shadow its own upstream.
    public func validate() -> String? {
        for backend in LocalLLMBackend.allCases where proxyEnabled(backend) {
            let listen = listenPort(backend), upstream = upstreamPort(backend)
            guard (1024...65535).contains(listen), (1...65535).contains(upstream) else { return "\(backend.displayName): port out of range" }
            if listen == upstream && ["127.0.0.1", "localhost", "::1"].contains(upstreamHost(backend)) {
                return "\(backend.displayName): the proxy port must differ from the server port"
            }
        }
        let listens = LocalLLMBackend.allCases.filter(proxyEnabled).map(listenPort)
        return Set(listens).count == listens.count ? nil : "two proxies use the same port"
    }
    /// Price-table id used for the equivalent cost.
    public var reference: String { LocalLLMReference.resolve(referenceModel).id }
}

public enum LocalLLMReference {
    /// A well-known mid-tier model ($2 in / $10 out per million tokens in the table). "Cheapest of a tier" is not stable across price reviews.
    public static let defaultModel = "claude-sonnet-5-5"
    public static func resolve(_ id: String?) -> ModelPrice {
        if let id, let price = ModelPrices.price(for: id) { return price }
        return ModelPrices.price(for: defaultModel) ?? ModelPrices.entries.first ?? ModelPrice(id: defaultModel, input: 2, output: 10)
    }
    /// Choices for a picker: every priced model, cheapest first.
    public static var choices: [ModelPrice] {
        ModelPrices.entries.sorted { ($0.input + $0.output, $0.id) < ($1.input + $1.output, $1.id) }
    }
}

/// One request (proxy), or the change in a server's counters since the previous poll (poller).
public struct LocalLLMEvent: Codable, Equatable {
    public var id: String
    public var t: Double
    /// `LocalLLMBackend` raw value.
    public var backend: String
    /// "proxy" or "poll".
    public var via: String
    public var model: String?
    /// Requests this event stands for; 0 when the server does not count them.
    public var requests: Int
    /// Requests among them for which the response carried no token counts.
    public var unmetered: Int
    /// Prompt tokens including cached ones.
    public var prompt: Double
    public var cached: Double
    public var completion: Double
    public var reasoning: Double
    /// Seconds spent on the uncached prompt tokens and on generating `completion` tokens, when known.
    public var promptSeconds: Double?
    public var genSeconds: Double?
    /// Total measured seconds of the request(s).
    public var seconds: Double?
    /// "engine" when the server reported the timings, "proxy" when the proxy derived them.
    public var timing: String?

    public init(id: String, t: Double, backend: String, via: String, model: String? = nil, requests: Int = 1, unmetered: Int = 0,
                prompt: Double = 0, cached: Double = 0, completion: Double = 0, reasoning: Double = 0,
                promptSeconds: Double? = nil, genSeconds: Double? = nil, seconds: Double? = nil, timing: String? = nil) {
        self.id = id; self.t = t; self.backend = backend; self.via = via; self.model = model; self.requests = requests
        self.unmetered = unmetered; self.prompt = prompt; self.cached = cached; self.completion = completion; self.reasoning = reasoning
        self.promptSeconds = promptSeconds; self.genSeconds = genSeconds; self.seconds = seconds; self.timing = timing
    }

    /// The same usage as a token event, so statistics, `quotapilot stats` and the menu line include it (provider `local`, $0).
    public var tokenEvent: AgentTokenEvent {
        let usage = TokenBreakdown(input: max(0, prompt - cached), cacheRead: min(cached, prompt), cacheWrite: 0,
                                   output: completion, reasoning: min(reasoning, completion))
        return AgentTokenEvent(provider: "local", timestamp: t, usage: usage, dedupeKey: "local|" + id,
                               model: (backend == LocalLLMBackend.custom.rawValue ? "local-server" : backend) + "/" + (model ?? "unknown"), calls: requests)
    }
}

/// Append-only event file shared by the app, `quotapilot local proxy` and `quotapilot stats`. One JSON object per line.
public final class LocalLLMLog {
    public static let retention: Double = 35 * 86400
    /// Events older than this are merged per hour, backend, model and source.
    public static let detailSeconds: Double = 2 * 86400
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }
    public static func defaultURL(stateDirectory: URL = Portable.stateDirectory()) -> URL {
        stateDirectory.appendingPathComponent("local-llm-events.jsonl")
    }

    public func append(_ events: [LocalLLMEvent]) {
        guard !events.isEmpty else { return }
        var data = Data()
        let encoder = JSONEncoder()
        for event in events { if let line = try? encoder.encode(event) { data.append(line); data.append(0x0A) } }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        // O_APPEND: lines from the app and a CLI proxy running at the same time do not interleave.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        _ = close(fd)
        #else
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        #endif
    }

    /// Events with `t >= since`, oldest first.
    public func events(since: Double = 0) -> [LocalLLMEvent] {
        readNew(from: 0).events.filter { $0.t >= since }
    }

    /// Events appended after byte `offset` and the offset to continue from. A shrunken file (compaction) restarts at 0.
    public func readNew(from offset: UInt64) -> (events: [LocalLLMEvent], offset: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let status = Portable.status(url.path), status.isRegular else { return ([], 0) }
        let start = status.size < offset ? 0 : offset
        guard status.size > start, let handle = try? FileHandle(forReadingFrom: url) else { return ([], status.size) }
        defer { try? handle.close() }
        handle.seek(toFileOffset: start)
        let data = handle.readData(ofLength: Int(min(status.size - start, 64 * 1_048_576)))
        // Stop at the last complete line so a half-written one is read next time.
        guard let last = data.lastIndex(of: 0x0A) else { return ([], start) }
        let complete = data.prefix(through: last)
        let decoder = JSONDecoder()
        let events = complete.split(separator: 0x0A).compactMap { try? decoder.decode(LocalLLMEvent.self, from: Data($0)) }
        return (events, start + UInt64(complete.count))
    }

    /// Drops events past retention and merges older ones per hour. Rewrites the file only when something changed.
    public func compact(now: Double) {
        let all = readNew(from: 0).events
        guard !all.isEmpty else { return }
        let merged = Self.compacted(all, now: now)
        guard merged.count != all.count else { return }
        lock.lock(); defer { lock.unlock() }
        var data = Data()
        let encoder = JSONEncoder()
        for event in merged { if let line = try? encoder.encode(event) { data.append(line); data.append(0x0A) } }
        try? data.write(to: url, options: .atomic)
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        _ = chmod(url.path, 0o600)
        #endif
    }

    static func compacted(_ events: [LocalLLMEvent], now: Double) -> [LocalLLMEvent] {
        var keep: [LocalLLMEvent] = []
        var groups: [String: LocalLLMEvent] = [:]
        for event in events {
            if event.t < now - retention { continue }
            guard event.t < now - detailSeconds else { keep.append(event); continue }
            let hour = Int64((event.t / 3600).rounded(.down) * 3600)
            let key = "\(hour)|\(event.backend)|\(event.via)|\(event.model ?? "")"
            if var group = groups[key] {
                group.requests += event.requests; group.unmetered += event.unmetered
                group.prompt += event.prompt; group.cached += event.cached; group.completion += event.completion; group.reasoning += event.reasoning
                group.promptSeconds = sum(group.promptSeconds, event.promptSeconds)
                group.genSeconds = sum(group.genSeconds, event.genSeconds)
                group.seconds = sum(group.seconds, event.seconds)
                if group.timing != event.timing { group.timing = group.timing == "engine" || event.timing == "engine" ? "engine" : group.timing ?? event.timing }
                groups[key] = group
            } else {
                var group = event
                group.id = "hour|" + key
                group.t = Double(hour)
                groups[key] = group
            }
        }
        return (groups.values.sorted { $0.t < $1.t }) + keep
    }
    private static func sum(_ a: Double?, _ b: Double?) -> Double? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
}

/// Per backend and model totals with speeds and the hypothetical cost on the reference cloud model.
public struct LocalLLMReport: Equatable {
    public struct Line: Equatable {
        public let backend: String
        public let model: String?
        public let requests: Int
        /// False when the server does not count requests (llama.cpp `/metrics`).
        public let requestsKnown: Bool
        /// Requests whose response had no token counts (streaming without `include_usage`).
        public let unmetered: Int
        public let prompt: Double
        public let cached: Double
        public let completion: Double
        public let reasoning: Double
        /// Uncached prompt tokens per second, over events that have a prompt time. Sum of tokens over sum of seconds.
        public let promptTokensPerSecond: Double?
        public let generationTokensPerSecond: Double?
        /// True when a speed comes from times the proxy measured rather than from the server.
        public let proxyMeasuredSpeed: Bool
        public let activeSeconds: Double
        /// Equivalent cost of these tokens on the reference model (hypothetical).
        public let costUSD: Double
        public var totalTokens: Double { prompt + completion }
        public var id: String { backend + "|" + (model ?? "") }
    }
    public let lines: [Line]
    public let reference: ModelPrice
    public let requests: Int
    public let unmetered: Int
    public let requestsKnown: Bool
    public let prompt: Double
    public let cached: Double
    public let completion: Double
    public let activeSeconds: Double
    public let costUSD: Double
    public var isEmpty: Bool { lines.isEmpty }
    public var totalTokens: Double { prompt + completion }

    /// Cost of `prompt` (including `cached`) and `completion` tokens on `price`.
    public static func cost(prompt: Double, cached: Double, completion: Double, price: ModelPrice) -> Double {
        let hit = min(max(cached, 0), prompt)
        return ((prompt - hit) * price.input + hit * (price.cacheRead ?? price.input) + completion * price.output) / 1_000_000
    }

    public init(events: [LocalLLMEvent], reference id: String? = nil) {
        let price = LocalLLMReference.resolve(id)
        struct Sums {
            var requests = 0, unmetered = 0, known = false
            var prompt = 0.0, cached = 0.0, completion = 0.0, reasoning = 0.0
            var promptTokens = 0.0, promptSeconds = 0.0, genTokens = 0.0, genSeconds = 0.0, seconds = 0.0
            var proxyTiming = false
        }
        var table: [String: (backend: String, model: String?, sums: Sums)] = [:]
        for event in events {
            let key = event.backend + "|" + (event.model ?? "")
            var entry = table[key] ?? (event.backend, event.model, Sums())
            entry.sums.requests += event.requests; entry.sums.unmetered += event.unmetered
            if event.requests > 0 { entry.sums.known = true }
            entry.sums.prompt += event.prompt; entry.sums.cached += event.cached
            entry.sums.completion += event.completion; entry.sums.reasoning += event.reasoning
            if let seconds = event.promptSeconds, seconds > 0 {
                entry.sums.promptSeconds += seconds; entry.sums.promptTokens += max(0, event.prompt - event.cached)
                if event.timing == "proxy" { entry.sums.proxyTiming = true }
            }
            if let seconds = event.genSeconds, seconds > 0 {
                entry.sums.genSeconds += seconds; entry.sums.genTokens += event.completion
                if event.timing == "proxy" { entry.sums.proxyTiming = true }
            }
            entry.sums.seconds += event.seconds ?? ((event.promptSeconds ?? 0) + (event.genSeconds ?? 0))
            table[key] = entry
        }
        var lines: [Line] = []
        for (_, entry) in table {
            let s = entry.sums
            guard s.requests > 0 || s.prompt > 0 || s.completion > 0 else { continue }
            lines.append(Line(backend: entry.backend, model: entry.model, requests: s.requests, requestsKnown: s.known, unmetered: s.unmetered,
                              prompt: s.prompt, cached: s.cached, completion: s.completion, reasoning: s.reasoning,
                              promptTokensPerSecond: s.promptSeconds > 0 ? s.promptTokens / s.promptSeconds : nil,
                              generationTokensPerSecond: s.genSeconds > 0 ? s.genTokens / s.genSeconds : nil,
                              proxyMeasuredSpeed: s.proxyTiming, activeSeconds: s.seconds,
                              costUSD: Self.cost(prompt: s.prompt, cached: s.cached, completion: s.completion, price: price)))
        }
        lines.sort { $0.totalTokens != $1.totalTokens ? $0.totalTokens > $1.totalTokens : $0.id < $1.id }
        self.lines = lines; self.reference = price
        requests = lines.reduce(0) { $0 + $1.requests }; unmetered = lines.reduce(0) { $0 + $1.unmetered }
        requestsKnown = lines.contains { $0.requestsKnown }
        prompt = lines.reduce(0) { $0 + $1.prompt }; cached = lines.reduce(0) { $0 + $1.cached }
        completion = lines.reduce(0) { $0 + $1.completion }
        activeSeconds = lines.reduce(0) { $0 + $1.activeSeconds }
        costUSD = lines.reduce(0) { $0 + $1.costUSD }
    }
}

public enum LocalLLMIntegration {
    /// While Local models is on, calls that Codex or Claude Code made to a local model are not booked from the agent logs:
    /// the same traffic reaches the meter, so booking both would count it twice (docs/local-llm.md, rule 2).
    public static func skipsAgentEvent(_ event: AgentTokenEvent, settings: LocalLLMSettings?) -> Bool {
        (settings?.isEnabled ?? false) && event.provider != "local" && ModelIdentity.isLocal(event.model)
    }
}
