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
    /// Backends whose usage reaches the meter: proxy on, or a poller that runs.
    public var meteredBackends: [LocalLLMBackend] {
        guard isEnabled else { return [] }
        return LocalLLMBackend.allCases.filter { proxyEnabled($0) || polls($0) }
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

/// Advisory lock on a file shared between processes (flock). Where there is no flock it always succeeds.
public final class ProcessLock {
    public let url: URL
    private var fd: Int32 = -1
    public init(url: URL) { self.url = url }
    deinit { release() }

    /// Takes the lock without waiting. `shared` locks can be held by many processes; an exclusive one by one, and not together with shared ones.
    public func tryAcquire(shared: Bool = false) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else { _ = close(descriptor); return false }
        fd = descriptor
        return true
        #else
        return true
        #endif
    }

    /// Blocks until the lock is free (exclusive).
    func acquireBlocking(shared: Bool = false) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, shared ? LOCK_SH : LOCK_EX) == 0 else { _ = close(descriptor); return false }
        fd = descriptor
        return true
        #else
        return true
        #endif
    }

    public func release() {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if fd >= 0 { _ = flock(fd, LOCK_UN); _ = close(fd); fd = -1 }
        #endif
    }

    /// True when another holder keeps a lock that conflicts with an exclusive one (checked and released at once).
    public static func isHeldElsewhere(_ url: URL) -> Bool {
        let probe = ProcessLock(url: url)
        guard probe.tryAcquire() else { return true }
        probe.release()
        return false
    }
}

/// Append-only event file shared by the app, `quotapilot local proxy` and `quotapilot stats`. One JSON object per line.
/// Every append and every compaction holds a lock file next to it (`.lock`, flock), so processes cannot lose each other's lines.
/// A compaction replaces the file by rename; readers notice that by the file's identity, not by its size.
public final class LocalLLMLog {
    public static let retention: Double = 35 * 86400
    /// Events older than this are merged per hour, backend, model and source.
    public static let detailSeconds: Double = 2 * 86400
    /// Bytes read at a time; tests make it small.
    static var chunkSize = 4 * 1_048_576
    public let url: URL
    private let lock = NSLock()
    private var lockURL: URL { URL(fileURLWithPath: url.path + ".lock") }

    /// Where a reader stopped: a byte offset in a particular file (identified by inode).
    public struct Cursor: Equatable {
        public var offset: UInt64 = 0
        public var identity: UInt64? = nil
        public init() {}
    }

    public init(url: URL) { self.url = url }
    public static func defaultURL(stateDirectory: URL = Portable.stateDirectory()) -> URL {
        stateDirectory.appendingPathComponent("local-llm-events.jsonl")
    }

    private func withFileLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        let file = ProcessLock(url: lockURL)
        let held = file.acquireBlocking()
        defer { if held { file.release() } }
        return body()
    }

    private static func encode(_ events: [LocalLLMEvent]) -> Data {
        var data = Data()
        let encoder = JSONEncoder()
        for event in events { if let line = try? encoder.encode(event) { data.append(line); data.append(0x0A) } }
        return data
    }

    public func append(_ events: [LocalLLMEvent]) {
        guard !events.isEmpty else { return }
        let data = Self.encode(events)
        withFileLock {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            // O_APPEND as well: a writer that does not know about the lock file still cannot overwrite.
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
    }

    /// Events with `t >= since`, oldest first.
    public func events(since: Double = 0) -> [LocalLLMEvent] {
        readNew(from: Cursor()).events.filter { $0.t >= since }
    }

    /// Events appended after the cursor and the cursor to continue from. When the file was replaced (compaction) the whole new file is
    /// read and `rewritten` is true: the caller must discard what it kept from the old one. Reads in chunks; there is no size limit.
    public func readNew(from cursor: Cursor) -> (events: [LocalLLMEvent], cursor: Cursor, rewritten: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], Cursor(), cursor.identity != nil || cursor.offset > 0) }
        defer { try? handle.close() }
        var identity: UInt64?
        var size: UInt64 = 0
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var info = stat()
        if fstat(handle.fileDescriptor, &info) == 0 { identity = UInt64(truncatingIfNeeded: info.st_ino) ^ (UInt64(truncatingIfNeeded: info.st_dev) << 40); size = UInt64(info.st_size) }
        #else
        size = Portable.status(url.path)?.size ?? 0
        #endif
        let rewritten = (cursor.identity != nil && identity != cursor.identity) || size < cursor.offset
        let start = rewritten ? 0 : cursor.offset
        var result = Cursor()
        result.identity = identity
        result.offset = start
        guard size > start else { return ([], result, rewritten) }
        handle.seek(toFileOffset: start)
        var events: [LocalLLMEvent] = []
        var carry = Data()
        let decoder = JSONDecoder()
        var consumed: UInt64 = 0
        while true {
            let chunk = handle.readData(ofLength: Self.chunkSize)
            if chunk.isEmpty { break }
            carry.append(chunk)
            guard let last = carry.lastIndex(of: 0x0A) else { continue }
            let complete = carry.prefix(through: last)
            for line in complete.split(separator: 0x0A) { if let event = try? decoder.decode(LocalLLMEvent.self, from: Data(line)) { events.append(event) } }
            consumed += UInt64(complete.count)
            carry = Data(carry.suffix(from: last + 1))
        }
        result.offset = start + consumed
        return (events, result, rewritten)
    }

    /// Drops events past retention and merges older ones per hour. The read and the replacement happen under the file lock,
    /// so a line appended meanwhile by another process is never lost. Rewrites only when something changed.
    public func compact(now: Double) {
        withFileLock {
            let all = readNew(from: Cursor()).events
            guard !all.isEmpty else { return }
            let merged = Self.compacted(all, now: now)
            guard merged.count != all.count else { return }
            let temporary = URL(fileURLWithPath: url.path + ".tmp")
            try? FileManager.default.removeItem(at: temporary)
            // Private from the first byte: permissions are set before the data is written, and the rename keeps them.
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: temporary) else { return }
            handle.write(Self.encode(merged))
            try? handle.close()
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            if rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
            #else
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
            #endif
        }
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

/// Follows the event file for one reader (the app): keeps the events of the last 30 days without duplicates, and says which
/// events are new to book into the statistics. A compaction by another process makes it rebuild its list from the new file;
/// nothing is booked twice (by id), and merged `hour|…` events are never booked, since the events they merge were booked when new.
public final class LocalLLMIngestor {
    public private(set) var events: [LocalLLMEvent] = []
    private var ids = Set<String>()
    private var booked: [String: Double] = [:]
    private var cursor = LocalLLMLog.Cursor()
    public static let keep: Double = 30 * 86400
    public init() {}

    public struct Update {
        public var bookable: [LocalLLMEvent]
        public var changed: Bool
    }

    /// - Parameter bookSince: events older than this are shown but not booked (the statistics already cover them).
    public func poll(_ log: LocalLLMLog, now: Double, bookSince: Double) -> Update {
        let read = log.readNew(from: cursor)
        cursor = read.cursor
        var changed = read.rewritten
        if read.rewritten { events = []; ids = [] }
        var bookable: [LocalLLMEvent] = []
        for event in read.events where ids.insert(event.id).inserted {
            events.append(event); changed = true
            if !event.id.hasPrefix("hour|"), event.t >= bookSince, booked[event.id] == nil {
                booked[event.id] = event.t; bookable.append(event)
            }
        }
        let cutoff = now - Self.keep
        if let first = events.first, first.t < cutoff || events.contains(where: { $0.t < cutoff }) {
            events = events.filter { $0.t >= cutoff }; ids = Set(events.map(\.id)); changed = true
        }
        booked = booked.filter { $0.value > now - 3 * 86400 }
        return Update(bookable: bookable, changed: changed)
    }
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
    private static let markers: [(LocalLLMBackend, [String])] = [
        (.ollama, ["ollama"]), (.lmstudio, ["lmstudio", "lm-studio"]), (.llamacpp, ["llama.cpp", "llamacpp"]),
        (.omlx, ["omlx"]), (.strata, ["strata"])]

    /// A call that Codex or Claude Code made to a local model is not booked from the agent logs when the same traffic reaches the meter,
    /// since booking both would count it twice (docs/local-llm.md, rule 2). A model id that names its backend is skipped only when that
    /// backend is metered (proxy on, or its poller running); an id that names none is skipped when any backend is metered.
    public static func skipsAgentEvent(_ event: AgentTokenEvent, settings: LocalLLMSettings?) -> Bool {
        guard let settings, event.provider != "local", ModelIdentity.isLocal(event.model) else { return false }
        let metered = settings.meteredBackends
        guard !metered.isEmpty else { return false }
        let id = ModelIdentity.normalize(event.model) ?? ""
        if let named = markers.first(where: { $0.1.contains { id.contains($0) } })?.0 { return metered.contains(named) }
        return true
    }
}
