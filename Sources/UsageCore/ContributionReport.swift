import Foundation

/// Builds the anonymous numbers `quotapilot share` offers to send to AI Quota Watch.
/// Nothing here reads or sends anything; the caller decides, after showing the result to the user.
/// Reports carry no paths, account ids, prompts or file names: only model ids, plan names,
/// token counts, durations and quota percentages, with times rounded to the hour.
public enum ContributionReport {
    /// One quota window as seen right now, plus the tokens the agent logged since that window started.
    public struct WindowUse: Equatable {
        public var provider: String          // "codex" or "claude"
        public var plan: String?
        public var windowMinutes: Int
        public var usedPercent: Double
        public var limitReached: Bool
        public var tokensSinceStart: TokenBreakdown
        public var model: String?
        /// When this window was first seen at its limit (nil when unknown).
        public var limitSince: Double?
        /// The window's reset time.
        public var resetAt: Double?
        public init(provider: String, plan: String?, windowMinutes: Int, usedPercent: Double, limitReached: Bool, tokensSinceStart: TokenBreakdown, model: String?,
                    limitSince: Double? = nil, resetAt: Double? = nil) {
            self.provider = provider; self.plan = plan; self.windowMinutes = windowMinutes; self.usedPercent = usedPercent
            self.limitReached = limitReached; self.tokensSinceStart = tokensSinceStart; self.model = model
            self.limitSince = limitSince; self.resetAt = resetAt
        }
    }

    /// Model ids in the site's form: lower case, dots to dashes, no `[1m]` or date suffix; nil for anything that is not a public model family.
    /// `gpt-6.1-sol` → `gpt-6-1-sol`, `claude-opus-5-5-20261001[1m]` → `claude-opus-5-5`.
    public static func siteModelID(_ raw: String?) -> String? {
        guard var id = raw?.lowercased().trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        id = id.replacingOccurrences(of: ".", with: "-")
        if let range = id.range(of: #"-20\d{6}$"#, options: .regularExpression) { id.removeSubrange(range) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard id.allSatisfy({ allowed.contains($0) }), id.count <= 60 else { return nil }
        // Only public model families are shared. A private deployment or a locally named model (which could carry a
        // company or project name) never leaves the computer; the collector applies the same rule.
        guard isPublicModelFamily(id) else { return nil }
        return id
    }

    /// Public model families the statistics cover. Kept in step with `collector/schema.js`.
    public static let publicModelPrefixes = ["gpt-", "codex-", "claude-", "gemini-", "grok-", "deepseek-", "kimi-", "glm-", "qwen-"]
    static func isPublicModelFamily(_ id: String) -> Bool {
        publicModelPrefixes.contains { id.hasPrefix($0) } || id.range(of: #"^o[0-9]"#, options: .regularExpression) != nil
    }

    public static func siteProvider(_ provider: String) -> String? {
        ["codex": "chatgpt", "claude": "claude", "gemini": "gemini", "grok": "grok"][provider]
    }

    public static func hourISO(_ time: Double) -> String {
        let rounded = (time / 3600).rounded(.down) * 3600
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: rounded))
    }

    /// Plan names as people know them: `pro` → `Pro`, `max_5x` → `Max 5x`.
    public static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    public static let minimumCallsPerModel = 3


    /// The agent behind a plan-wide quota window (`codex:primary`, `claude:five_hour:primary`), or nil for
    /// per-model buckets, which would double count.
    public static func sharedProvider(windowID: String) -> String? {
        let bucket = windowID.split(separator: ":").dropLast().joined(separator: ":")
        switch bucket {
        case "codex": return "codex"
        case "claude:five_hour", "claude:seven_day": return "claude"
        default: return nil
        }
    }

    /// Current plan windows with the tokens logged since each window opened.
    public static func windowUses(items: [WindowItem], tokensSince: (String, Double) -> TokenBreakdown, model: (String) -> String?,
                                  limitSince: (String, Double?) -> Double? = { _, _ in nil }) -> [WindowUse] {
        items.compactMap { item in
            guard let provider = sharedProvider(windowID: item.id), let used = item.window.validUsedPercent,
                  let mins = item.window.windowDurationMins, let reset = item.window.resetsAt else { return nil }
            let start = reset - Double(mins) * 60
            return WindowUse(provider: provider, plan: item.planType, windowMinutes: mins, usedPercent: used,
                             limitReached: item.limitReached, tokensSinceStart: tokensSince(provider, start), model: model(provider),
                             limitSince: limitSince(item.id, reset), resetAt: reset)
        }
    }


    /// The tool that wrote the log, from the sample key (`codex|…`, `claude|…`, `gemini|…`). Claude Code
    /// pointed at another model family still counts as Claude Code.
    static func clientName(_ sample: OutputSpeedSample) -> String {
        let source = sample.key.split(separator: "|").first.map(String.init) ?? sample.provider
        return ["codex": "Codex", "claude": "Claude Code", "gemini": "Gemini CLI", "grok": "Grok CLI"][source] ?? "Claude Code"
    }

    /// A share keeps the busiest rows, so one report stays small.
    public static let maximumReports = 30

    /// Effort labels shared by Codex and Claude Code; anything else is dropped rather than sent.
    static func effortName(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased() else { return nil }
        let known = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        return known.contains(raw) ? raw : nil
    }

    public static func build(speed: [OutputSpeedSample], windows: [WindowUse], now: Double,
                             include: Set<ShareCategory> = Set(ShareCategory.allCases)) -> [[String: Any]] {
        var reports: [[String: Any]] = []
        let date = hourISO(now)

        // Speed and real usage: one report per model and reasoning effort, with total output tokens,
        // the reasoning part of them, and total call time.
        let keyed = speed.compactMap { s -> (String, OutputSpeedSample)? in
            guard let model = siteModelID(s.model) else { return nil }
            return (model + "|" + (effortName(s.effort) ?? ""), s)
        }
        for (key, pairs) in Dictionary(grouping: keyed, by: \.0).sorted(by: { $0.key < $1.key }) where include.contains(.speed) {
            let samples = pairs.map(\.1)
            guard samples.count >= minimumCallsPerModel, let summary = OutputSpeedSummary(samples), summary.seconds > 0 else { continue }
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            var report: [String: Any] = ["type": "speed", "model": String(parts[0]), "client": clientName(samples[0]),
                                         "outputTokens": summary.outputTokens.rounded(), "seconds": max(1, summary.seconds.rounded()),
                                         "reasoningTokens": samples.reduce(0) { $0 + $1.reasoningTokens }.rounded(),
                                         "calls": summary.calls, "date": date, "via": "quotapilot"]
            if parts.count > 1, !parts[1].isEmpty { report["effort"] = String(parts[1]) }
            // Prompt side, for the site's input/output and prompt-cache statistics. Totals only.
            let input = samples.reduce(0) { $0 + $1.inputTokens }, cacheRead = samples.reduce(0) { $0 + $1.cacheReadTokens }
            let cacheWrite = samples.reduce(0) { $0 + $1.cacheWriteTokens }
            if include.contains(.promptCache), input + cacheRead + cacheWrite > 0 {
                report["inputTokens"] = input.rounded(); report["cacheReadTokens"] = cacheRead.rounded(); report["cacheWriteTokens"] = cacheWrite.rounded()
            }
            reports.append(report)
        }

        // Quota: tokens since the window opened ÷ share of the limit used. Cache reads are left out:
        // they are cheap and would swamp the count.
        var limitEvents = Set<String>()
        for use in windows {
            guard let provider = siteProvider(use.provider) else { continue }
            let window: String
            switch use.windowMinutes { case 300: window = "5h"; case 10080: window = "weekly"; default: continue }
            let tokens = use.tokensSinceStart.input + use.tokensSinceStart.cacheWrite + use.tokensSinceStart.output
            // A 5-hour window below 10% is too coarse to extrapolate from.
            if include.contains(.quota), use.usedPercent >= (window == "5h" ? 10 : 1), tokens >= 1000, let plan = planName(use.plan) {
                var report: [String: Any] = ["type": "quota", "provider": provider, "plan": plan, "window": window,
                                             "percentUsed": (use.usedPercent * 10).rounded() / 10, "tokensUsed": tokens.rounded(),
                                             "date": date, "via": "quotapilot"]
                if tokens > 0 {
                    let share = (use.tokensSinceStart.input + use.tokensSinceStart.cacheWrite) / tokens
                    report["inputShare"] = (share * 1000).rounded() / 1000
                }
                if let model = siteModelID(use.model) { report["model"] = model }
                reports.append(report)
            }
            // Only with a known first-seen time: no data is better than the share time.
            if include.contains(.limitEvents), use.limitReached, let since = use.limitSince, limitEvents.insert(provider + "|" + window).inserted {
                var event: [String: Any] = ["type": "event", "provider": provider, "plan": planName(use.plan) ?? "", "kind": "hit_limit", "date": hourISO(since), "via": "quotapilot"]
                if let resetAt = use.resetAt { event["resetAt"] = hourISO(resetAt) }
                reports.append(event)
            }
        }
        if reports.count > maximumReports {
            let calls = { (r: [String: Any]) -> Int in (r["calls"] as? Int) ?? Int.max }
            reports = Array(reports.sorted { calls($0) > calls($1) }.prefix(maximumReports))
        }
        return reports
    }
}

/// What a share may contain; each kind can be turned off on its own.
public enum ShareCategory: String, CaseIterable, Codable {
    /// Output speed, reasoning tokens, call counts and time per model and effort.
    case speed
    /// Prompt-side totals: new input, cache reads and cache writes (part of each speed report).
    case promptCache
    /// Share of a 5-hour or weekly window used, with the tokens spent in it.
    case quota
    /// That a plan limit was reached, with the hour.
    case limitEvents
}
