import Foundation

/// Token counts by purpose. `input` excludes cached input; `reasoning` is a subset of `output`
/// for providers that report it, so it is not added to the total again.
public struct TokenBreakdown: Codable, Equatable {
    public var input: Double = 0
    public var cacheRead: Double = 0
    public var cacheWrite: Double = 0
    public var output: Double = 0
    public var reasoning: Double = 0
    public init(input: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, output: Double = 0, reasoning: Double = 0) {
        self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.output = output; self.reasoning = reasoning
    }
    public var total: Double { input + cacheRead + cacheWrite + output }
    public var isEmpty: Bool { total <= 0 }
    public mutating func add(_ other: TokenBreakdown) {
        input += other.input; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
        output += other.output; reasoning += other.reasoning
    }
    /// Field-wise growth from `previous` to `self` (never negative), for logs that rewrite a call as it streams.
    public func growth(since previous: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(input: max(0, input - previous.input), cacheRead: max(0, cacheRead - previous.cacheRead),
                       cacheWrite: max(0, cacheWrite - previous.cacheWrite), output: max(0, output - previous.output),
                       reasoning: max(0, reasoning - previous.reasoning))
    }
    /// Field-wise maximum.
    public func merged(with other: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(input: max(input, other.input), cacheRead: max(cacheRead, other.cacheRead), cacheWrite: max(cacheWrite, other.cacheWrite),
                       output: max(output, other.output), reasoning: max(reasoning, other.reasoning))
    }
}

/// Remembers the usage already counted for each call, so a repeated log line adds nothing and a call rewritten
/// with larger numbers while it streams adds only the growth, in the bucket of its first sighting.
struct CountedCalls: Codable {
    private(set) var first: [String: Double] = [:]
    private(set) var usage: [String: TokenBreakdown] = [:]
    /// Returns the timestamp to book under and the usage not yet counted, or nil when nothing is new.
    mutating func uncounted(_ event: AgentTokenEvent) -> (timestamp: Double, usage: TokenBreakdown)? {
        guard let at = first[event.dedupeKey] else {
            first[event.dedupeKey] = event.timestamp; usage[event.dedupeKey] = event.usage
            return (event.timestamp, event.usage)
        }
        let previous = usage[event.dedupeKey] ?? TokenBreakdown()
        let growth = event.usage.growth(since: previous)
        guard !growth.isEmpty || growth.reasoning > 0 else { return nil }
        usage[event.dedupeKey] = previous.merged(with: event.usage)
        return (at, growth)
    }
    func contains(_ key: String) -> Bool { first[key] != nil }
    mutating func keep(where include: (Double) -> Bool) {
        first = first.filter { include($0.value) }
        usage = usage.filter { first[$0.key] != nil }
    }
}

public struct AgentTokenEvent: Equatable {
    public let provider: String
    public let timestamp: Double
    public let usage: TokenBreakdown
    /// Identifies the same API call when a session log is forked or replayed into another file.
    public let dedupeKey: String
}

/// Parses token usage from local agent session logs. Only numeric usage fields are read;
/// prompts, outputs and file contents are never kept.
public enum AgentLogParser {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func timestamp(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        return (isoFractional.date(from: text) ?? iso.date(from: text))?.timeIntervalSince1970
    }

    private static func number(_ value: Any?) -> Double {
        guard let n = value as? NSNumber else { return 0 }
        let d = n.doubleValue
        return d.isFinite && d > 0 ? d : 0
    }

    /// Codex rollout JSONL: `event_msg` lines whose payload is a `token_count` with `info.last_token_usage`.
    public static func codexEvent(_ line: String) -> AgentTokenEvent? {
        guard line.contains("\"token_count\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let time = timestamp(object["timestamp"]) else { return nil }
        let input = number(last["input_tokens"]), cached = number(last["cached_input_tokens"])
        let written = number(last["cache_write_input_tokens"]), output = number(last["output_tokens"])
        let usage = TokenBreakdown(input: max(0, input - cached - written), cacheRead: cached, cacheWrite: written,
                                   output: output, reasoning: min(output, number(last["reasoning_output_tokens"])))
        guard !usage.isEmpty else { return nil }
        let cumulative = (info["total_token_usage"] as? [String: Any]).map { number($0["total_tokens"]) } ?? 0
        return AgentTokenEvent(provider: "codex", timestamp: time, usage: usage,
                               dedupeKey: "codex|\(object["timestamp"] as? String ?? "")|\(Int64(cumulative))|\(Int64(usage.total))")
    }

    /// Claude Code project JSONL: `assistant` lines with `message.usage`. Streaming writes the same
    /// message more than once, so the message and request ids identify one call.
    public static func claudeEvent(_ line: String) -> AgentTokenEvent? {
        guard line.contains("\"usage\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let time = timestamp(object["timestamp"]) else { return nil }
        let breakdown = TokenBreakdown(input: number(usage["input_tokens"]), cacheRead: number(usage["cache_read_input_tokens"]),
                                       cacheWrite: number(usage["cache_creation_input_tokens"]), output: number(usage["output_tokens"]))
        guard !breakdown.isEmpty else { return nil }
        let id = (message["id"] as? String) ?? (object["uuid"] as? String) ?? "\(time)"
        return AgentTokenEvent(provider: providerForModel(message["model"] as? String), timestamp: time, usage: breakdown,
                               dedupeKey: "claude|\(id)|\(object["requestId"] as? String ?? "")")
    }
}

extension AgentLogParser {
    /// Gemini CLI chat recordings (`~/.gemini/tmp/<project>/chats/*.jsonl`): `gemini` messages carry
    /// `tokens` {input (includes cached), cached, output, thoughts, tool}. Messages can be written more
    /// than once with the same id, so the id identifies one call.
    public static func geminiEvent(_ line: String) -> AgentTokenEvent? {
        guard line.contains("\"tokens\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "gemini", let tokens = object["tokens"] as? [String: Any],
              let time = timestamp(object["timestamp"]) else { return nil }
        let cached = number(tokens["cached"]), thoughts = number(tokens["thoughts"])
        let usage = TokenBreakdown(input: max(0, number(tokens["input"]) - cached) + number(tokens["tool"]), cacheRead: cached,
                                   cacheWrite: 0, output: number(tokens["output"]) + thoughts, reasoning: thoughts)
        guard !usage.isEmpty else { return nil }
        return AgentTokenEvent(provider: "gemini", timestamp: time, usage: usage,
                               dedupeKey: "gemini|\(object["id"] as? String ?? "\(time)")")
    }

    /// Grok CLI unified log (`~/.grok/logs/unified.jsonl`): `shell.turn.inference_done` lines with
    /// `ctx` {prompt_tokens (includes cached), cached_prompt_tokens, completion_tokens, reasoning_tokens}.
    public static func grokEvent(_ line: String) -> AgentTokenEvent? {
        guard line.contains("inference_done"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["msg"] as? String == "shell.turn.inference_done", let ctx = object["ctx"] as? [String: Any],
              let time = timestamp(object["ts"]) else { return nil }
        let cached = number(ctx["cached_prompt_tokens"]), output = number(ctx["completion_tokens"])
        let usage = TokenBreakdown(input: max(0, number(ctx["prompt_tokens"]) - cached), cacheRead: cached, cacheWrite: 0,
                                   output: output, reasoning: min(output, number(ctx["reasoning_tokens"])))
        guard !usage.isEmpty else { return nil }
        let loop = (ctx["loop_index"] as? NSNumber)?.intValue ?? -1
        return AgentTokenEvent(provider: "grok", timestamp: time, usage: usage,
                               dedupeKey: "grok|\(object["sid"] as? String ?? "")|\(loop)|\(object["ts"] as? String ?? "")")
    }

    /// Claude Code can be pointed at other Anthropic-compatible APIs (DeepSeek, Kimi, GLM, Qwen…).
    /// Attribute usage by the model family that actually answered.
    public static func providerForModel(_ model: String?) -> String {
        guard let model = model?.lowercased(), !model.isEmpty, !model.hasPrefix("claude"), !model.hasPrefix("<") else { return "claude" }
        for family in ["deepseek", "kimi", "moonshot", "glm", "qwen", "minimax", "gemini", "gpt"] where model.contains(family) {
            return family == "moonshot" ? "kimi" : family
        }
        return "claude"
    }
}

/// Five-minute buckets per provider, deduplicated, kept for at most `retention` seconds.
public struct AgentTokenLedger {
    public static let bucketSeconds: Double = 300
    public let retention: Double
    private var buckets: [String: [Double: TokenBreakdown]] = [:]
    private var seen = CountedCalls()
    public init(retention: Double = 31 * 86400) { self.retention = retention }

    /// Counts a call once; a later line for the same call with larger numbers adds only the difference.
    @discardableResult
    public mutating func add(_ event: AgentTokenEvent) -> Bool {
        guard let (timestamp, usage) = seen.uncounted(event) else { return false }
        let start = (timestamp / Self.bucketSeconds).rounded(.down) * Self.bucketSeconds
        buckets[event.provider, default: [:]][start, default: TokenBreakdown()].add(usage)
        return true
    }

    public mutating func prune(now: Double) {
        let cutoff = now - retention
        seen.keep { $0 >= cutoff }
        for provider in Array(buckets.keys) {
            buckets[provider] = buckets[provider]?.filter { $0.key + Self.bucketSeconds > cutoff }
            if buckets[provider]?.isEmpty == true { buckets.removeValue(forKey: provider) }
        }
    }

    /// Usage per provider for buckets that overlap `[since, now]`.
    public func summary(since: Double, now: Double) -> [String: TokenBreakdown] {
        var result: [String: TokenBreakdown] = [:]
        for (provider, series) in buckets {
            for (start, usage) in series where start + Self.bucketSeconds > since && start <= now {
                result[provider, default: TokenBreakdown()].add(usage)
            }
        }
        return result
    }

    public func total(since: Double, now: Double) -> TokenBreakdown {
        summary(since: since, now: now).values.reduce(into: TokenBreakdown()) { $0.add($1) }
    }
}

/// Incrementally reads agent JSONL logs. New files are read backwards from the end only as far as the
/// requested window, so a multi-gigabyte session log does not have to be read in full.
public final class AgentLogScanner {
    public struct Source {
        public let provider: String
        public let root: URL
        public let parse: (String) -> AgentTokenEvent?
        public let parseModel: ((String) -> AgentModelEvent?)?
        public init(provider: String, root: URL, parse: @escaping (String) -> AgentTokenEvent?,
                    parseModel: ((String) -> AgentModelEvent?)? = nil) {
            self.provider = provider; self.root = root; self.parse = parse; self.parseModel = parseModel
        }
    }
    public let sources: [Source]
    private var offsets: [String: UInt64] = [:]
    /// Bytes read by the last `scan`, for diagnostics.
    public private(set) var lastScanBytes: UInt64 = 0
    private let chunkSize = 4 * 1_048_576

    private let isCancelled: () -> Bool
    public init(sources: [Source], isCancelled: @escaping () -> Bool = { false }) {
        self.sources = sources; self.isCancelled = isCancelled
    }

    public static func defaultSources(home: URL) -> [Source] {
        [Source(provider: "codex", root: home.appendingPathComponent(".codex/sessions", isDirectory: true), parse: AgentLogParser.codexEvent,
                parseModel: AgentLogParser.codexModelEvent),
         Source(provider: "claude", root: home.appendingPathComponent(".claude/projects", isDirectory: true), parse: AgentLogParser.claudeEvent,
                parseModel: AgentLogParser.claudeModelEvent),
         Source(provider: "gemini", root: home.appendingPathComponent(".gemini/tmp", isDirectory: true), parse: AgentLogParser.geminiEvent,
                parseModel: AgentLogParser.geminiModelEvent),
         Source(provider: "grok", root: home.appendingPathComponent(".grok/logs", isDirectory: true), parse: AgentLogParser.grokEvent)]
    }

    private var knownFiles: [String: Int] = [:]  // path -> source index
    private var lastFullEnumeration: Double = -.infinity
    /// Directory walks are slow on large or external volumes, so between full walks only known files and
    /// today's date folders (Codex stores rollouts under YYYY/MM/DD) are checked.
    public var fullEnumerationInterval: Double = 1800

    /// Returns events newer than `windowStart` that were not returned before.
    public func scan(windowStart: Double, now: Double = Date().timeIntervalSince1970) -> [AgentTokenEvent] {
        var events: [AgentTokenEvent] = []
        lastScanBytes = 0
        lastModelEvents = []
        lastSpeedSamples = []
        let full = now - lastFullEnumeration >= fullEnumerationInterval
        if full { lastFullEnumeration = now }
        for (index, source) in sources.enumerated() {
            if isCancelled() { break }
            let root = source.root.resolvingSymlinksInPath()
            var candidates = Set(knownFiles.filter { $0.value == index }.map(\.key))
            let roots = full ? [root] : recentDayFolders(root: root, now: now)
            for folder in roots { candidates.formUnion(jsonlFiles(in: folder)) }
            for path in candidates.sorted() {
                if isCancelled() { break }
                knownFiles[path] = index
                events += scanFile(URL(fileURLWithPath: path), source: source, windowStart: windowStart)
            }
        }
        if isCancelled() {
            // Discarding this batch must also rewind files completed earlier in the same scan.
            offsets.removeAll(); timers.removeAll(); lastFullEnumeration = -.infinity
            lastModelEvents = []; lastSpeedSamples = []
            return []
        }
        return events
    }

    /// Lists every log file modified since `windowStart`, oldest first, for a resumable backfill.
    public func backfillCandidates(windowStart: Double) -> [(path: String, source: Int)] {
        var result: [(String, Int, Double)] = []
        for (index, source) in sources.enumerated() {
            if isCancelled() { break }
            for path in jsonlFiles(in: source.root.resolvingSymlinksInPath()) {
                if isCancelled() { break }
                guard let modified = Portable.status(path)?.modified else { continue }
                if modified >= windowStart { result.append((path, index, modified)) }
            }
        }
        return result.sorted { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    /// Reads one file's events since `windowStart` without remembering an offset (backfill only).
    public func backfillFile(_ path: String, source index: Int, windowStart: Double) -> [AgentTokenEvent] {
        guard sources.indices.contains(index) else { return [] }
        let events = scanFile(URL(fileURLWithPath: path), source: sources[index], windowStart: windowStart)
        offsets.removeValue(forKey: path)
        return events
    }

    private func recentDayFolders(root: URL, now: Double) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        let days = [0, -86400].flatMap { offset -> [URL] in
            let date = Date(timeIntervalSince1970: now + offset)
            return [TimeZone.current, TimeZone(identifier: "UTC")!].map { zone in
                let parts = calendar.dateComponents(in: zone, from: date)
                return root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0), isDirectory: true)
            }
        }
        let existing = Array(Set(days.filter { FileManager.default.fileExists(atPath: $0.path) }))
        // Layouts without date folders (Claude Code projects) are small enough to list each time.
        return existing.isEmpty && !FileManager.default.fileExists(atPath: root.appendingPathComponent(String(format: "%04d", calendar.component(.year, from: Date(timeIntervalSince1970: now)))).path) ? [root] : existing
    }

    private func jsonlFiles(in folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if isCancelled() { break }
            result.append(url.path)
        }
        return result
    }

    private func scanFile(_ url: URL, source: Source, windowStart: Double) -> [AgentTokenEvent] {
        let key = url.path
        // POSIX stat: FileManager.attributesOfItem can take ~100 ms per file on some external volumes.
        guard let info = Portable.status(key), info.isRegular else {
            knownFiles.removeValue(forKey: key); offsets.removeValue(forKey: key); return []
        }
        let size = info.size, modified = info.modified
        guard modified >= windowStart else { return [] }
        let events: [AgentTokenEvent]
        if let offset = offsets[key] {
            if size < offset {
                offsets[key] = 0
                events = readForward(url, from: 0, size: size, source: source, windowStart: windowStart)
            } else {
                events = size > offset ? readForward(url, from: offset, size: size, source: source, windowStart: windowStart) : []
            }
        } else {
            events = readBackward(url, size: size, source: source, windowStart: windowStart)
        }
        guard !isCancelled() else {
            // A partially read file is retried in full; never persist an offset past unprocessed usage.
            offsets.removeValue(forKey: key); timers.removeValue(forKey: key)
            return []
        }
        return events
    }

    private func readForward(_ url: URL, from offset: UInt64, size: UInt64, source: Source, windowStart: Double) -> [AgentTokenEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var events: [AgentTokenEvent] = []
        var position = offset
        var carry = Data()
        while position < size && !isCancelled() {
            guard (try? handle.seek(toOffset: position)) != nil,
                  let chunk = try? handle.read(upToCount: Int(min(UInt64(chunkSize), size - position))), !chunk.isEmpty else { break }
            position += UInt64(chunk.count)
            lastScanBytes += UInt64(chunk.count)
            carry.append(chunk)
            guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
            let complete = carry[carry.startIndex...lastNewline]
            events += parseLines(complete, source: source, path: url.path).filter { $0.timestamp >= windowStart }
            carry = Data(carry[carry.index(after: lastNewline)...])
        }
        // Keep a trailing partial line for the next scan.
        offsets[url.path] = position - UInt64(carry.count)
        return events
    }

    private func readBackward(_ url: URL, size: UInt64, source: Source, windowStart: Double) -> [AgentTokenEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var events: [AgentTokenEvent] = []
        var end = size
        var tail = Data()
        // Bytes after the final newline belong to a line that is still being written.
        if size > 0, (try? handle.seek(toOffset: size - 1)) != nil, let last = try? handle.read(upToCount: 1), last != Data([0x0A]) {
            var probe = size
            while probe > 0 && !isCancelled() {
                let start = probe > UInt64(chunkSize) ? probe - UInt64(chunkSize) : 0
                guard (try? handle.seek(toOffset: start)) != nil, let chunk = try? handle.read(upToCount: Int(probe - start)) else { break }
                if let newline = chunk.lastIndex(of: 0x0A) { end = start + UInt64(chunk.distance(from: chunk.startIndex, to: newline)) + 1; break }
                probe = start
                if start == 0 { end = 0 }
            }
        }
        offsets[url.path] = end
        var cursor = end
        while cursor > 0 && !isCancelled() {
            let start = cursor > UInt64(chunkSize) ? cursor - UInt64(chunkSize) : 0
            guard (try? handle.seek(toOffset: start)) != nil, var chunk = try? handle.read(upToCount: Int(cursor - start)) else { break }
            lastScanBytes += UInt64(chunk.count)
            chunk.append(tail)
            var body = chunk
            if start > 0 {
                // The text before the first newline ends a line that starts in the previous chunk.
                guard let firstNewline = chunk.firstIndex(of: 0x0A) else { tail = chunk; cursor = start; continue }
                tail = Data(chunk[chunk.startIndex...firstNewline].dropLast())
                body = Data(chunk[chunk.index(after: firstNewline)...])
            } else { tail = Data() }
            let parsed = parseLines(body, source: source)
            events += parsed.filter { $0.timestamp >= windowStart }
            cursor = start
            if let oldest = parsed.map(\.timestamp).min(), oldest < windowStart { break }
        }
        if cursor == 0, !tail.isEmpty { events += parseLines(tail, source: source).filter { $0.timestamp >= windowStart } }
        return events
    }

    /// Model observations found by the last scan (requested/served models and reroutes).
    public private(set) var lastModelEvents: [AgentModelEvent] = []
    /// Per-call output speed found by the last scan. Calls that span a read boundary are skipped.
    public private(set) var lastSpeedSamples: [OutputSpeedSample] = []

    /// Returns and clears samples collected outside `scan` (backfill reads).
    public func takeSpeedSamples() -> [OutputSpeedSample] {
        defer { lastSpeedSamples = [] }
        return lastSpeedSamples
    }

    /// Call timers carried across incremental reads, so a request and its response written in different
    /// scans are still paired.
    private var timers: [String: CallTimer] = [:]

    private func parseLines(_ data: Data, source: Source, path: String? = nil) -> [AgentTokenEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var events: [AgentTokenEvent] = []
        var timer = path.flatMap { timers[$0] } ?? CallTimer(provider: source.provider)
        defer { if let path { timers[path] = timer } }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if isCancelled() { break }
            let string = String(line)
            if let event = source.parse(string) { events.append(event) }
            if let parseModel = source.parseModel, let model = parseModel(string) { lastModelEvents.append(model) }
            lastSpeedSamples += timer.feed(string)
        }
        // Claude responses finish with their last block; keep them open while the file is still being written.
        if path == nil { lastSpeedSamples += timer.flush() }
        return events
    }
}
