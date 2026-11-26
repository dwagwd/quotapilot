import Foundation

/// Tokens and calls booked under one model in one time bucket.
public struct ModelSlice: Codable, Equatable {
    public var usage = TokenBreakdown()
    public var calls = 0
    public init() {}
    public mutating func add(_ usage: TokenBreakdown, calls: Int) { self.usage.add(usage); self.calls += calls }
}

/// Keys of the per-model tables: "provider|model". An empty model part means the log names no model
/// (or older data that predates model tracking); "other" collects models beyond the cap.
public enum ModelKey {
    /// Most distinct provider/model keys kept; further ones are folded into "provider|other".
    public static let maxDistinct = 64
    public static let other = "other"

    public static func key<V>(provider: String, model: String?, existing: [String: V]) -> String {
        let candidate = provider + "|" + (model ?? "")
        if existing[candidate] != nil || existing.count < maxDistinct || model == nil { return candidate }
        return provider + "|" + other
    }

    public static func split(_ key: String) -> (provider: String, model: String?) {
        guard let bar = key.firstIndex(of: "|") else { return (key, nil) }
        let model = String(key[key.index(after: bar)...])
        return (String(key[..<bar]), model.isEmpty ? nil : model)
    }
}

public struct ModelPrice: Equatable {
    public let id: String
    /// USD per million tokens (list price).
    public let input: Double
    public let output: Double
    /// Absent when the vendor's page has no cached-input price we could read: reads are then charged at `input`.
    public let cacheRead: Double?
    /// 5-minute prompt-cache write (Anthropic). Absent: charged at `input`.
    public let cacheWrite: Double?
    init(id: String, input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.id = id; self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

public enum ModelPrices {
    private static let byID: [String: ModelPrice] = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// Price entry for a model id as found in a log, or nil. Matching is tolerant: case, vendor prefixes
    /// (`anthropic/`, `models/`, `us.anthropic.`), `[1m]` suffixes, date suffixes (`-20261101`, `-2026-11-01`, `@20261101`),
    /// `-latest`, `-preview`, Bedrock `-v1:0`, and dots versus dashes (`gpt-6.1-sol` = `gpt-6-1-sol`) are ignored.
    public static func price(for model: String?) -> ModelPrice? {
        guard let id = ModelIdentity.canonical(model) else { return nil }
        return byID[id]
    }
}

public enum ModelIdentity {
    /// Lowercase model id as found in a log; nil for empty or placeholder names (`<synthetic>`).
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty, !id.hasPrefix("<") else { return nil }
        return String(id.prefix(100))
    }

    private static let suffixes: [NSRegularExpression] = [
        #"\[[^\]]*\]$"#, #"-v\d+(:\d+)?$"#, #"[-@]\d{8}$"#, #"-\d{4}-\d{2}-\d{2}$"#, #"-latest$"#, #"-preview(-\d{2,4}(-\d{2})?)?$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// The form used for price lookup: vendor prefix, bracket/date/preview suffixes removed, dots and underscores as dashes.
    static func canonical(_ raw: String?) -> String? {
        guard var id = normalize(raw) else { return nil }
        if let range = id.range(of: "anthropic.") { id = String(id[range.upperBound...]) }
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        var changed = true
        while changed {
            changed = false
            for expression in suffixes {
                let range = NSRange(id.startIndex..., in: id)
                if let match = expression.firstMatch(in: id, range: range), let swiftRange = Range(match.range, in: id) {
                    id.removeSubrange(swiftRange); changed = true
                }
            }
        }
        id = id.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "_", with: "-")
        return id.isEmpty ? nil : id
    }

    /// Heuristic for models run on this computer (Ollama, LM Studio, llama.cpp): the id names such a runtime or a
    /// quantized file format, comes from Hugging Face, or carries a `:tag` such as `qwen3:8b` or `llama3.1:70b`.
    /// A purely numeric tag (Bedrock's `-v1:0`) and Claude ids do not count. Local models are not billed ($0).
    /// Local families written without a tag (`llama-3-8b`) are not detected.
    public static func isLocal(_ raw: String?) -> Bool {
        guard let id = normalize(raw) else { return false }
        for marker in ["ollama", "lmstudio", "lm-studio", "gguf", "llama.cpp", "llamacpp", "hf.co/", "huggingface.co/"] where id.contains(marker) {
            return true
        }
        guard let colon = id.firstIndex(of: ":"), !id.hasPrefix("claude"), !id.contains("anthropic.") else { return false }
        let tag = id[id.index(after: colon)...]
        return !tag.isEmpty && !tag.allSatisfy(\.isNumber)
    }
}

/// Usage of one provider/model pair over a range. `model == nil` means unknown.
public struct ModelUsage: Equatable {
    public var provider: String
    public var model: String?
    public var usage: TokenBreakdown
    public var calls: Int
    public init(provider: String, model: String?, usage: TokenBreakdown, calls: Int) {
        self.provider = provider; self.model = model; self.usage = usage; self.calls = calls
    }
}

/// Everything the statistics need from a ledger or store for one range.
public struct UsageStatsInput: Equatable {
    public var rows: [ModelUsage]
    /// Five-minute buckets with any activity.
    public var activeSlots: Int
    public init(rows: [ModelUsage], activeSlots: Int) { self.rows = rows; self.activeSlots = activeSlots }

    /// Per-model totals plus, per provider, whatever the provider totals hold beyond them (usage recorded before
    /// models were tracked) as a row without a model and zero calls.
    static func make(modelTotals: [String: ModelSlice], providerTotals: [String: TokenBreakdown], activeSlots: Int) -> UsageStatsInput {
        var rows: [ModelUsage] = []
        var attributed: [String: TokenBreakdown] = [:]
        for (key, slice) in modelTotals where !slice.usage.isEmpty || slice.calls > 0 {
            let (provider, model) = ModelKey.split(key)
            rows.append(ModelUsage(provider: provider, model: model, usage: slice.usage, calls: slice.calls))
            attributed[provider, default: TokenBreakdown()].add(slice.usage)
        }
        for (provider, total) in providerTotals {
            let rest = total.growth(since: attributed[provider] ?? TokenBreakdown())
            if !rest.isEmpty {
                if let index = rows.firstIndex(where: { $0.provider == provider && $0.model == nil }) { rows[index].usage.add(rest) }
                else { rows.append(ModelUsage(provider: provider, model: nil, usage: rest, calls: 0)) }
            }
        }
        return UsageStatsInput(rows: rows, activeSlots: activeSlots)
    }
}

/// Cost, cache and share figures for a range. Costs are what the same tokens would cost at API list prices
/// (a subscription does not pay this), for priced models only.
public struct UsageReport: Equatable {
    public enum PriceStatus: String, Equatable { case priced, local, notPriced }
    public struct Line: Equatable {
        public let id: String
        public let provider: String
        public let model: String?
        public let usage: TokenBreakdown
        public let calls: Int
        public let status: PriceStatus
        /// nil when not priced; 0 for local models.
        public let costUSD: Double?
        /// Share of all tokens.
        public let share: Double
    }
    public struct Category: Equatable {
        public enum Kind: String, CaseIterable { case cacheRead, newInput, output, reasoning }
        public let kind: Kind
        public let tokens: Double
        public let share: Double
    }
    public let total: TokenBreakdown
    public let calls: Int
    public let activeMinutes: Double
    public let costUSD: Double
    /// Tokens of models with no known price (excluded from `costUSD`).
    public let unpricedTokens: Double
    public let localTokens: Double
    public let cacheHitRate: Double?
    public let cacheSavingsUSD: Double
    public let categories: [Category]
    public let providers: [Line]
    public let models: [Line]
    public var hasUnpriced: Bool { unpricedTokens > 0 }

    /// Dollar cost of one row with the fallbacks documented in `ModelPrice`.
    static func cost(_ usage: TokenBreakdown, _ price: ModelPrice) -> Double {
        (usage.input * price.input + usage.cacheRead * (price.cacheRead ?? price.input)
            + usage.cacheWrite * (price.cacheWrite ?? price.input) + usage.output * price.output) / 1_000_000
    }

    /// Money not spent on cache reads versus paying the input price, where the cache-read price is known.
    static func savings(_ usage: TokenBreakdown, _ price: ModelPrice) -> Double {
        guard let read = price.cacheRead else { return 0 }
        return usage.cacheRead * max(0, price.input - read) / 1_000_000
    }

    public init(_ input: UsageStatsInput) {
        var total = TokenBreakdown(), calls = 0, cost = 0.0, unpriced = 0.0, local = 0.0, savings = 0.0
        var modelLines: [String: (provider: String, model: String?, usage: TokenBreakdown, calls: Int, status: PriceStatus, cost: Double)] = [:]
        var providerLines: [String: (usage: TokenBreakdown, calls: Int, priced: Bool, cost: Double)] = [:]
        for row in input.rows {
            let local_ = ModelIdentity.isLocal(row.model)
            let price = local_ ? nil : ModelPrices.price(for: row.model)
            let status: PriceStatus = local_ ? .local : price != nil ? .priced : .notPriced
            let rowCost = price.map { Self.cost(row.usage, $0) } ?? 0
            total.add(row.usage); calls += row.calls; cost += rowCost
            if status == .notPriced { unpriced += row.usage.total } else if status == .local { local += row.usage.total }
            if let price { savings += Self.savings(row.usage, price) }
            let provider = local_ ? "local" : row.provider
            let key = provider + "|" + (row.model ?? "")
            var line = modelLines[key] ?? (provider, row.model, TokenBreakdown(), 0, status, 0)
            line.usage.add(row.usage); line.calls += row.calls; line.cost += rowCost
            modelLines[key] = line
            var group = providerLines[provider] ?? (TokenBreakdown(), 0, false, 0)
            group.usage.add(row.usage); group.calls += row.calls; group.cost += rowCost
            group.priced = group.priced || status != .notPriced
            providerLines[provider] = group
        }
        let all = max(total.total, 1)
        func make(_ id: String, _ provider: String, _ model: String?, _ usage: TokenBreakdown, _ calls: Int, _ status: PriceStatus, _ cost: Double) -> Line {
            Line(id: id, provider: provider, model: model, usage: usage, calls: calls, status: status,
                 costUSD: status == .notPriced ? nil : cost, share: usage.total / all)
        }
        self.models = modelLines.map { make($0.key, $0.value.provider, $0.value.model, $0.value.usage, $0.value.calls, $0.value.status, $0.value.cost) }
            .sorted { $0.usage.total != $1.usage.total ? $0.usage.total > $1.usage.total : $0.id < $1.id }
        self.providers = providerLines.map { make($0.key, $0.key, nil, $0.value.usage, $0.value.calls, $0.value.priced ? .priced : .notPriced, $0.value.cost) }
            .sorted { $0.usage.total != $1.usage.total ? $0.usage.total > $1.usage.total : $0.id < $1.id }
        self.total = total; self.calls = calls; self.costUSD = cost
        self.unpricedTokens = unpriced; self.localTokens = local; self.cacheSavingsUSD = savings
        self.activeMinutes = Double(input.activeSlots) * AgentTokenLedger.bucketSeconds / 60
        let prompt = total.input + total.cacheRead + total.cacheWrite
        self.cacheHitRate = prompt > 0 ? total.cacheRead / prompt : nil
        let visibleOutput = max(0, total.output - total.reasoning)
        let parts: [(Category.Kind, Double)] = [(.cacheRead, total.cacheRead), (.newInput, total.input + total.cacheWrite),
                                                (.output, visibleOutput), (.reasoning, min(total.reasoning, total.output))]
        self.categories = parts.map { Category(kind: $0.0, tokens: $0.1, share: $0.1 / all) }
    }
}
