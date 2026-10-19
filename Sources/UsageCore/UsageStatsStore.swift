import Foundation

public struct QuotaSample: Codable, Equatable {
    public let t: Double
    public let used: Double
    public let reset: Double?
    public init(t: Double, used: Double, reset: Double?) { self.t = t; self.used = used; self.reset = reset }
}

public struct TokenSeriesPoint: Equatable {
    public let start: Double
    public let provider: String
    public let tokens: Double
}

/// Long-term usage history for the statistics window: hourly token totals per provider and sparse quota
/// samples per window, kept for `retention` seconds and saved as one small JSON file.
public struct UsageStatsStore: Codable {
    public static let retention: Double = 35 * 86400
    public static let quotaSampleInterval: Double = 600
    /// Events older than this were either counted before or predate the history; it moves forward on save.
    public private(set) var acceptAfter: Double = 0
    public private(set) var backfilledAt: Double?
    public private(set) var quotaBackfilledAt: Double?
    /// Log files already read by an unfinished backfill, so a restart continues instead of starting over.
    public private(set) var backfilledFiles: Set<String>? = nil
    private var tokenHours: [String: [String: TokenBreakdown]] = [:]
    private var recentKeys: [String: Double] = [:]
    private var quotaSamples: [String: [QuotaSample]] = [:]
    /// Output tokens and model-call seconds per provider per hour, for output speed (decode lower bound).
    private var speedHours: [String: [String: [Double]]]? = nil
    public private(set) var windowTitles: [String: String] = [:]
    private static let recentKeySpan: Double = 6 * 3600

    public init() {}

    private static func hourKey(_ t: Double) -> String { String(Int64((t / 3600).rounded(.down) * 3600)) }

    /// Adds a token event once. Returns false for duplicates and for events at or before `acceptAfter`.
    @discardableResult
    public mutating func add(_ event: AgentTokenEvent) -> Bool {
        guard event.timestamp > acceptAfter, recentKeys[event.dedupeKey] == nil else { return false }
        recentKeys[event.dedupeKey] = event.timestamp
        tokenHours[event.provider, default: [:]][Self.hourKey(event.timestamp), default: TokenBreakdown()].add(event.usage)
        return true
    }

    @discardableResult
    public mutating func addSpeed(_ sample: OutputSpeedSample) -> Bool {
        let key = "speed|" + sample.key
        guard sample.timestamp > acceptAfter, recentKeys[key] == nil else { return false }
        recentKeys[key] = sample.timestamp
        var hours = speedHours ?? [:]
        var pair = hours[sample.provider]?[Self.hourKey(sample.timestamp)] ?? [0, 0]
        pair[0] += sample.outputTokens; pair[1] += sample.seconds
        hours[sample.provider, default: [:]][Self.hourKey(sample.timestamp)] = pair
        speedHours = hours
        return true
    }

    /// Output tokens per second of model-call time per provider since `since`.
    public func outputSpeed(since: Double, now: Double) -> [String: (tokensPerSecond: Double, outputTokens: Double, seconds: Double)] {
        var result: [String: (Double, Double, Double)] = [:]
        for (provider, hours) in speedHours ?? [:] {
            var tokens = 0.0, seconds = 0.0
            for (key, pair) in hours where pair.count == 2 {
                guard let start = Double(key), start + 3600 > since, start <= now else { continue }
                tokens += pair[0]; seconds += pair[1]
            }
            if seconds > 0 { result[provider] = (tokens / seconds, tokens, seconds) }
        }
        return result
    }

    /// Hourly or daily output speed per provider, oldest first; empty buckets are omitted.
    public func speedSeries(since: Double, now: Double, bucket: Double) -> [TokenSeriesPoint] {
        let size = max(3600, (bucket / 3600).rounded() * 3600)
        var sums: [String: [Double: [Double]]] = [:]
        for (provider, hours) in speedHours ?? [:] {
            for (key, pair) in hours where pair.count == 2 {
                guard let start = Double(key), start + 3600 > since, start <= now else { continue }
                let slot = (start / size).rounded(.down) * size
                var acc = sums[provider]?[slot] ?? [0, 0]; acc[0] += pair[0]; acc[1] += pair[1]
                sums[provider, default: [:]][slot] = acc
            }
        }
        return sums.keys.sorted().flatMap { provider in
            (sums[provider] ?? [:]).sorted { $0.key < $1.key }.compactMap { slot, acc in
                acc[1] > 0 ? TokenSeriesPoint(start: slot, provider: provider, tokens: acc[0] / acc[1]) : nil
            }
        }
    }

    /// Marks a 30-day log backfill as done; regular scans then only add newer events.
    public mutating func finishBackfill(at time: Double) {
        backfilledAt = time
        backfilledFiles = nil
    }

    public mutating func markBackfilled(file: String) {
        var files = backfilledFiles ?? []
        files.insert(file)
        backfilledFiles = files
    }

    public mutating func finishQuotaBackfill(at time: Double) { quotaBackfilledAt = time }

    /// Records a quota reading at most every ten minutes per window, or sooner when the value or reset changes.
    public mutating func recordQuota(windowID: String, title: String, used: Double?, resetsAt: Double?, now: Double) {
        guard let used, used.isFinite, (0...100).contains(used), now.isFinite else { return }
        windowTitles[windowID] = title
        var samples = quotaSamples[windowID] ?? []
        if let last = samples.last {
            guard now > last.t else { return }
            if now - last.t < Self.quotaSampleInterval && last.used == used && last.reset == resetsAt { return }
        }
        samples.append(QuotaSample(t: now, used: used, reset: resetsAt))
        quotaSamples[windowID] = samples
    }

    /// Before saving: forget dedupe keys older than six hours and stop accepting events from that far back.
    /// While a backfill is still running, older events must stay acceptable, so the watermark does not move.
    public mutating func prune(now: Double) {
        let cutoff = now - Self.retention
        if backfilledAt != nil { acceptAfter = max(acceptAfter, now - Self.recentKeySpan) }
        recentKeys = recentKeys.filter { $0.value > acceptAfter }
        for provider in Array(tokenHours.keys) {
            tokenHours[provider] = tokenHours[provider]?.filter { (Double($0.key) ?? 0) + 3600 > cutoff }
            if tokenHours[provider]?.isEmpty == true { tokenHours.removeValue(forKey: provider) }
        }
        if var hours = speedHours {
            for provider in Array(hours.keys) {
                hours[provider] = hours[provider]?.filter { (Double($0.key) ?? 0) + 3600 > cutoff }
                if hours[provider]?.isEmpty == true { hours.removeValue(forKey: provider) }
            }
            speedHours = hours
        }
        for id in Array(quotaSamples.keys) {
            quotaSamples[id] = quotaSamples[id]?.filter { $0.t > cutoff }
            if quotaSamples[id]?.isEmpty == true { quotaSamples.removeValue(forKey: id); windowTitles.removeValue(forKey: id) }
        }
    }

    public var providers: [String] { tokenHours.keys.sorted() }
    public var quotaWindowIDs: [String] { quotaSamples.keys.sorted() }

    public func tokenTotals(since: Double, now: Double) -> [String: TokenBreakdown] {
        var result: [String: TokenBreakdown] = [:]
        for (provider, hours) in tokenHours {
            for (key, usage) in hours {
                guard let start = Double(key), start + 3600 > since, start <= now else { continue }
                result[provider, default: TokenBreakdown()].add(usage)
            }
        }
        return result
    }

    /// Token totals per provider in buckets of `bucket` seconds (a multiple of an hour), oldest first.
    /// Buckets without usage are reported as zero so lines drop to the baseline instead of interpolating.
    public func tokenSeries(since: Double, now: Double, bucket: Double) -> [TokenSeriesPoint] {
        let size = max(3600, (bucket / 3600).rounded() * 3600)
        let first = (since / size).rounded(.down) * size
        var sums: [String: [Double: Double]] = [:]
        for (provider, hours) in tokenHours {
            for (key, usage) in hours {
                guard let start = Double(key), start >= first, start <= now else { continue }
                sums[provider, default: [:]][(start / size).rounded(.down) * size, default: 0] += usage.total
            }
        }
        var points: [TokenSeriesPoint] = []
        for provider in sums.keys.sorted() {
            var start = first
            while start <= now {
                points.append(TokenSeriesPoint(start: start, provider: provider, tokens: sums[provider]?[start] ?? 0))
                start += size
            }
        }
        return points
    }

    public func quotaSeries(windowID: String, since: Double) -> [QuotaSample] {
        (quotaSamples[windowID] ?? []).filter { $0.t >= since }
    }

    /// Average percentage points consumed per hour of observed time. Increases count; a drop or a new reset time
    /// starts a new cycle whose value counts from zero. Gaps over six hours are excluded from observed time.
    public func quotaConsumptionPerHour(windowID: String, since: Double) -> (perHour: Double, consumed: Double, hours: Double)? {
        let samples = quotaSeries(windowID: windowID, since: since)
        guard samples.count >= 2 else { return nil }
        var consumed = 0.0, seconds = 0.0
        for (previous, current) in zip(samples, samples.dropFirst()) {
            let gap = current.t - previous.t
            guard gap > 0, gap <= 6 * 3600 else { continue }
            seconds += gap
            let reset = current.used < previous.used || (current.reset != previous.reset && current.reset != nil && previous.reset != nil && abs((current.reset ?? 0) - (previous.reset ?? 0)) > 60)
            consumed += reset ? current.used : max(0, current.used - previous.used)
        }
        guard seconds >= 600 else { return nil }
        return (consumed / (seconds / 3600), consumed, seconds / 3600)
    }
}
