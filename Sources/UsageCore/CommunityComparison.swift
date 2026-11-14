import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// "How do my numbers compare with everyone who shares?" Reads the published community statistics
/// (`community.json` on AI Quota Watch: aggregates only, rows with at least 3 people) and lines them up with
/// this computer's own numbers, computed the same way a share would compute them. Nothing is sent: it is a plain
/// download of a public file, through the same cookie-free session the share uses.
public enum CommunityComparison {
    public static var statsURL: URL {
        URL(string: ProcessInfo.processInfo.environment["QUOTAPILOT_COMMUNITY_URL"] ?? "https://aiquotawatch.pages.dev/data/community.json")!
    }

    /// One published row: a model's output speed across people (median and middle half).
    public struct SpeedRow: Equatable {
        public let model: String
        public let people: Int
        public let median: Double
        public let p25: Double?
        public let p75: Double?
    }

    /// One published plan row: tokens that fit in a whole window (5-hour or weekly), across people.
    public struct QuotaRow: Equatable {
        public let provider: String
        public let plan: String
        public let window: String
        public let people: Int
        public let medianTokens: Double
    }

    public struct Published: Equatable {
        public let generated: String?
        public let people: Int
        public let minPeople: Int
        public let speed: [SpeedRow]
        public let quota: [QuotaRow]
    }

    /// Reads `community.json`. Unknown or malformed rows are skipped, never guessed.
    public static func parse(_ data: Data) -> Published? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func number(_ value: Any?) -> Double? { (value as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
        let speed = (object["speed"] as? [[String: Any]] ?? []).compactMap { row -> SpeedRow? in
            guard let model = row["model"] as? String, let n = number(row["n"]), let median = number(row["median"]), median > 0 else { return nil }
            return SpeedRow(model: model, people: Int(n), median: median, p25: number(row["p25"]), p75: number(row["p75"]))
        }
        let quota = (object["quota"] as? [[String: Any]] ?? []).compactMap { row -> QuotaRow? in
            guard let provider = row["provider"] as? String, let plan = row["plan"] as? String, let window = row["window"] as? String,
                  let n = number(row["n"]), let tokens = number(row["medianTokens"]), tokens > 0 else { return nil }
            return QuotaRow(provider: provider, plan: plan, window: window, people: Int(n), medianTokens: tokens)
        }
        let totals = object["totals"] as? [String: Any]
        return Published(generated: object["generated"] as? String, people: Int(number(totals?["reporters"]) ?? 0),
                         minPeople: Int(number(object["minSamples"]) ?? 3), speed: speed, quota: quota)
    }

    /// One line of the comparison, ready to show.
    public struct Line: Equatable {
        public enum Kind: String { case speed, quota }
        public let kind: Kind
        /// Model id for speed, "Plan · window" for quota.
        public let subject: String
        public let mine: Double
        public let median: Double
        public let people: Int
        /// mine / median: 1.2 means 20% more than the typical person.
        public var ratio: Double { median > 0 ? mine / median : 0 }
    }

    /// Lines up this computer's numbers (the same report dictionaries a share would send) with the published rows.
    /// Only subjects that are published (3 or more people) appear; everything else is left out.
    public static func compare(mine reports: [[String: Any]], with published: Published) -> [Line] {
        func number(_ value: Any?) -> Double? { (value as? Double) ?? (value as? NSNumber)?.doubleValue ?? (value as? Int).map(Double.init) }
        var lines: [Line] = []
        // Speed: total output tokens over total call time, per model (all efforts together, like the published row).
        var byModel: [String: (tokens: Double, seconds: Double)] = [:]
        for report in reports where report["type"] as? String == "speed" {
            guard let model = report["model"] as? String, let tokens = number(report["outputTokens"]), let seconds = number(report["seconds"]), seconds > 0 else { continue }
            byModel[model, default: (0, 0)].tokens += tokens
            byModel[model, default: (0, 0)].seconds += seconds
        }
        for row in published.speed.sorted(by: { $0.model < $1.model }) {
            guard let mine = byModel[row.model], mine.seconds > 0 else { continue }
            lines.append(Line(kind: .speed, subject: row.model, mine: mine.tokens / mine.seconds, median: row.median, people: row.people))
        }
        // Quota: tokens that would fill the whole window at this computer's pace (tokens used / share used), with the
        // same rule as the published rows: a 5-hour window needs at least 10% used.
        for report in reports where report["type"] as? String == "quota" {
            guard let provider = report["provider"] as? String, let plan = report["plan"] as? String, let window = report["window"] as? String,
                  let used = number(report["tokensUsed"]), let percent = number(report["percentUsed"]), percent >= (window == "5h" ? 10 : 1),
                  let row = published.quota.first(where: { $0.provider == provider && $0.plan == plan && $0.window == window }) else { continue }
            lines.append(Line(kind: .quota, subject: plan + " · " + window, mine: used / (percent / 100), median: row.medianTokens, people: row.people))
        }
        return lines
    }

    /// Downloads the published statistics. Same cookie-free session and fixed headers as the share.
    public static func fetch(url: URL = statsURL, timeout: Double = 20) -> Published? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let done = DispatchSemaphore(value: 0)
        var result: Published?
        ShareSubmitter.privateSession.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data { result = parse(data) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 5)
        return result
    }

    /// "12% faster than the median of 5 people", in plain words, English only for the CLI.
    public static func describe(_ line: Line) -> String {
        let percent = Int((abs(line.ratio - 1) * 100).rounded())
        let thing = line.kind == .speed ? "output speed" : "tokens per full window"
        let mine = line.kind == .speed ? String(format: "%.0f tok/s", line.mine) : compact(line.mine) + " tokens"
        let median = line.kind == .speed ? String(format: "%.0f tok/s", line.median) : compact(line.median) + " tokens"
        let how: String
        if percent < 5 { how = "about the same as" }
        else if line.kind == .speed { how = "\(percent)% \(line.ratio > 1 ? "faster" : "slower") than" }
        else { how = "\(percent)% \(line.ratio > 1 ? "more" : "fewer") than" }
        return "\(line.subject): your \(thing) \(mine) is \(how) the median \(median) of \(line.people) people"
    }

    static func compact(_ value: Double) -> String {
        value >= 1e9 ? String(format: "%.1fB", value / 1e9) : value >= 1e6 ? String(format: "%.1fM", value / 1e6) : value >= 1e3 ? String(format: "%.0fK", value / 1e3) : String(format: "%.0f", value)
    }
}
