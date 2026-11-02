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
        public init(provider: String, plan: String?, windowMinutes: Int, usedPercent: Double, limitReached: Bool, tokensSinceStart: TokenBreakdown, model: String?) {
            self.provider = provider; self.plan = plan; self.windowMinutes = windowMinutes; self.usedPercent = usedPercent
            self.limitReached = limitReached; self.tokensSinceStart = tokensSinceStart; self.model = model
        }
    }

    /// Model ids in the site's form: lower case, dots to dashes, no `[1m]` or date suffix.
    /// `gpt-6.1-sol` → `gpt-6-1-sol`, `claude-opus-5-5-20261001[1m]` → `claude-opus-5-5`.
    public static func siteModelID(_ raw: String?) -> String? {
        guard var id = raw?.lowercased().trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        id = id.replacingOccurrences(of: ".", with: "-")
        if let range = id.range(of: #"-20\d{6}$"#, options: .regularExpression) { id.removeSubrange(range) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard id.allSatisfy({ allowed.contains($0) }), id.count <= 60 else { return nil }
        return id
    }

    public static func siteProvider(_ provider: String) -> String? {
        ["codex": "chatgpt", "claude": "claude", "gemini": "gemini", "grok": "grok", "antigravity": "antigravity", "cursor": "cursor"][provider]
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

    /// The tool that wrote the log, from the sample key (`codex|…`, `claude|…`, `gemini|…`). Claude Code
    /// pointed at another model family still counts as Claude Code.
    static func clientName(_ sample: OutputSpeedSample) -> String {
        let source = sample.key.split(separator: "|").first.map(String.init) ?? sample.provider
        return ["codex": "Codex", "claude": "Claude Code", "gemini": "Gemini CLI", "grok": "Grok CLI"][source] ?? "Claude Code"
    }

    /// GitHub issue links break past roughly 8 KB, so a share keeps the busiest rows.
    public static let maximumReports = 30

    /// Effort labels shared by Codex and Claude Code; anything else is dropped rather than sent.
    static func effortName(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased() else { return nil }
        let known = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        return known.contains(raw) ? raw : nil
    }

    public static func build(speed: [OutputSpeedSample], windows: [WindowUse], now: Double) -> [[String: Any]] {
        var reports: [[String: Any]] = []
        let date = hourISO(now)

        // Speed and real usage: one report per model and reasoning effort, with total output tokens,
        // the reasoning part of them, and total call time.
        let keyed = speed.compactMap { s -> (String, OutputSpeedSample)? in
            guard let model = siteModelID(s.model) else { return nil }
            return (model + "|" + (effortName(s.effort) ?? ""), s)
        }
        for (key, pairs) in Dictionary(grouping: keyed, by: \.0).sorted(by: { $0.key < $1.key }) {
            let samples = pairs.map(\.1)
            guard samples.count >= minimumCallsPerModel, let summary = OutputSpeedSummary(samples), summary.seconds > 0 else { continue }
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            var report: [String: Any] = ["type": "speed", "model": String(parts[0]), "client": clientName(samples[0]),
                                         "outputTokens": summary.outputTokens.rounded(), "seconds": max(1, summary.seconds.rounded()),
                                         "reasoningTokens": samples.reduce(0) { $0 + $1.reasoningTokens }.rounded(),
                                         "calls": summary.calls, "date": date, "via": "quotapilot"]
            if parts.count > 1, !parts[1].isEmpty { report["effort"] = String(parts[1]) }
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
            if use.usedPercent >= 1, tokens >= 1000, let plan = planName(use.plan) {
                var report: [String: Any] = ["type": "quota", "provider": provider, "plan": plan, "window": window,
                                             "percentUsed": (use.usedPercent * 10).rounded() / 10, "tokensUsed": tokens.rounded(),
                                             "date": date, "via": "quotapilot"]
                if let model = siteModelID(use.model) { report["model"] = model }
                reports.append(report)
            }
            if use.limitReached, limitEvents.insert(provider).inserted {
                reports.append(["type": "event", "provider": provider, "plan": planName(use.plan) ?? "", "kind": "hit_limit", "date": date, "via": "quotapilot"])
            }
        }
        if reports.count > maximumReports {
            let calls = { (r: [String: Any]) -> Int in (r["calls"] as? Int) ?? Int.max }
            reports = Array(reports.sorted { calls($0) > calls($1) }.prefix(maximumReports))
        }
        return reports
    }
}
