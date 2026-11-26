import Foundation

// Opt-in sharing of local model speed together with a coarse description of the computer and the inference engine
// (PRIVACY.md, "Local runs"). Built from the local usage events; nothing here sends anything.
// Strict by design: only public open-weight model families, sizes and quantizations from fixed lists, engines from a fixed
// list, hardware in coarse buckets. Anything that does not fit is left out on this computer, and collector/schema.js refuses it again.

/// A local model id (Ollama tag, LM Studio / Hugging Face name, GGUF file name) reduced to the parts that may be shared.
public enum LocalModelName {
    public struct Parsed: Equatable {
        /// Family and version without size and quantization, in the site's form: `qwen3`, `llama3-1`, `qwen3-a3b-instruct`.
        public let id: String
        /// Parameter count in billions when the name carries one (`30b`, `270m`, `8x7b`).
        public let paramsB: Double?
        /// One of `quantizations`, canonical spelling.
        public let quant: String?
    }

    /// Public open-weight families. Kept in step with `LOCAL_FAMILIES` in `collector/schema.js` (a test compares them).
    public static let families = ["llama", "codellama", "mistral", "mixtral", "ministral", "magistral", "devstral", "codestral", "gemma", "phi", "qwen", "qwq",
                                  "deepseek", "glm", "kimi", "granite", "olmo", "smollm", "nemotron", "minimax", "yi", "internlm", "command", "aya",
                                  "starcoder", "hermes", "falcon", "exaone", "solar", "gpt-oss"]
    /// Extra words that may follow the family in a model name; a name with any other word is not shared.
    static let words: Set<String> = ["instruct", "chat", "it", "base", "coder", "code", "thinking", "reasoning", "vl", "vision", "mini", "small", "large",
                                     "medium", "tiny", "preview", "latest", "moe", "distill", "r1", "flash", "lite", "math", "turbo", "next", "omni",
                                     "max", "plus", "guard", "embed", "mlx", "gguf", "text", "dev", "air", "scout", "maverick"]
    public static let quantizations = ["Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L", "Q4_0", "Q4_1", "Q4_K_S", "Q4_K_M", "Q5_0", "Q5_1", "Q5_K_S", "Q5_K_M", "Q6_K", "Q8_0",
                                       "IQ2", "IQ3", "IQ4", "2bit", "3bit", "4bit", "5bit", "6bit", "8bit", "FP8", "FP16", "BF16", "MXFP4", "NVFP4", "INT4", "INT8", "AWQ", "GPTQ"]

    private static let quantPattern = #"(?<![a-z0-9])(q[2-8]_k_[sml]|q[2-8]_k|q[2-8]_[01]|iq[1-4](?:_[a-z]+)?|[2-8]bit|fp8|fp16|f16|bf16|mxfp4|nvfp4|int[48]|awq|gptq)(?![a-z0-9])"#

    static func canonicalQuant(_ token: String) -> String? {
        let t = token.lowercased()
        switch t {
        case "f16": return "FP16"
        case "q4_k", "q3_k", "q5_k": return t.uppercased() + "_M"
        default: break
        }
        if t.hasPrefix("iq"), let base = t.split(separator: "_").first.map({ String($0).uppercased() }), quantizations.contains(base) { return base }
        let candidate = t.hasSuffix("bit") ? t : t.uppercased()
        return quantizations.contains(candidate) ? candidate : nil
    }

    public static func parse(_ raw: String?) -> Parsed? {
        guard var name = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 160 else { return nil }
        // A registry path (hf.co/user/repo:tag, mlx-community/Model-4bit) shares only its last component, never the user or organisation.
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.hasSuffix(".gguf") { name = String(name.dropLast(5)) }
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_:.".contains($0)) }) else { return nil }
        var quant: String?
        if let regex = try? NSRegularExpression(pattern: quantPattern), let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let range = Range(match.range(at: 1), in: name) {
            guard let canonical = canonicalQuant(String(name[range])) else { return nil }
            quant = canonical
            name = regex.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "-")
        }
        let tokens = name.split(whereSeparator: { "-_:".contains($0) }).map(String.init)
        guard let head = tokens.first else { return nil }
        var kept: [String] = []
        var params: Double?
        var index = 0
        // First word: a family, optionally with its version glued on (`qwen3`, `llama3.1`); `gpt` only as `gpt-oss`.
        if isFamilyToken(head) {
            kept.append(head); index = 1
        } else if head == "gpt", tokens.count > 1, tokens[1] == "oss" {
            kept.append("gpt-oss"); index = 2
        } else { return nil }
        while index < tokens.count {
            let token = tokens[index]; index += 1
            if let size = size(token) { if params == nil { params = size }; continue }
            if token.range(of: #"^a[0-9]+(\.[0-9]+)?b$"#, options: .regularExpression) != nil { kept.append(token); continue }
            if token.range(of: #"^v?[0-9]{1,4}(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil { kept.append(token); continue }
            if token == "gguf" || token == "mlx" { continue }   // file and repository format words, not part of the model
            if words.contains(token) || isFamilyToken(token) { kept.append(token); continue }
            return nil   // an unknown word could be a project, company or person: nothing is shared
        }
        let id = kept.joined(separator: "-").replacingOccurrences(of: ".", with: "-")
        guard id.count <= 48, id.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { return nil }
        return Parsed(id: id, paramsB: params, quant: quant)
    }

    /// `qwen3`, `llama3.1`, `gemma3n`, `phi4`, `deepseek`: a family name with an optional version (and up to two letters) glued on.
    static func isFamilyToken(_ token: String) -> Bool {
        families.filter { $0 != "gpt-oss" }.contains { family in
            guard token.hasPrefix(family) else { return false }
            return String(token.dropFirst(family.count)).range(of: #"^([0-9]{1,2}(\.[0-9]{1,2})?[a-z]{0,2})?$"#, options: .regularExpression) != nil
        }
    }

    private static func size(_ token: String) -> Double? {
        if let match = token.range(of: #"^[0-9]+x[0-9]+(\.[0-9]+)?b$"#, options: .regularExpression), match == token.startIndex..<token.endIndex {
            let parts = token.dropLast().split(separator: "x")
            if parts.count == 2, let n = Double(parts[0]), let each = Double(parts[1]) { return n * each }
        }
        if token.range(of: #"^[0-9]+(\.[0-9]+)?b$"#, options: .regularExpression) != nil { return Double(token.dropLast()) }
        if token.range(of: #"^[0-9]+m$"#, options: .regularExpression) != nil, let m = Double(token.dropLast()) { return m / 1000 }
        return nil
    }
}

/// Engine names a report may carry (the app emits the first six); kept in step with `collector/schema.js`.
public enum LocalEngineName {
    public static func shared(_ backend: String) -> String {
        LocalLLMBackend(rawValue: backend).map { $0 == .custom ? "other" : $0.rawValue } ?? "other"
    }

    /// Engine version as coarse as is useful: `major.minor` for numbered releases (`0.5`), `b4567` for llama.cpp builds. nil when unknown.
    public static func coarseVersion(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        if let match = raw.range(of: #"^b[0-9]{1,6}"#, options: .regularExpression) { return String(raw[match]) }
        if let match = raw.range(of: #"^v?([0-9]{1,4})\.([0-9]{1,3})"#, options: .regularExpression) {
            return String(raw[match]).replacingOccurrences(of: "v", with: "")
        }
        return nil
    }

    /// Versions of the engines that answer on this computer and say their version cheaply: Ollama (`/api/version`) and
    /// llama.cpp (`/props`, `build_info`). Short timeouts; only loopback addresses; nothing for engines without such an endpoint.
    public static func detectVersions(settings: LocalLLMSettings, backends: Set<String>) -> [String: String] {
        var found: [String: String] = [:]
        if backends.contains(LocalLLMBackend.ollama.rawValue), isLocal(settings, .ollama),
           let reply = LocalHTTP.get(port: settings.upstreamPort(.ollama), path: "/api/version", timeout: 0.5), reply.status == 200,
           let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any], let version = coarseVersion(object["version"] as? String) {
            found["ollama"] = version
        }
        if backends.contains(LocalLLMBackend.llamacpp.rawValue), isLocal(settings, .llamacpp) {
            for port in LocalLLMBackend.llamacpp.pollPorts {
                if let reply = LocalHTTP.get(port: port, path: "/props", timeout: 0.5), reply.status == 200,
                   let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any], let version = coarseVersion(object["build_info"] as? String) {
                    found["llamacpp"] = version; break
                }
            }
        }
        return found
    }

    /// An engine reached on this computer (the proxy's upstream is loopback). A model served from another machine says nothing about this hardware.
    public static func isLocal(_ settings: LocalLLMSettings, _ backend: LocalLLMBackend) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(settings.upstreamHost(backend))
    }
}

/// Measured speed of one model on one engine, from the local usage events.
public struct LocalRunGroup: Equatable {
    public let backend: String
    public let model: LocalModelName.Parsed
    /// Median generation tokens per second over the events that carry a generation time.
    public let genTokensPerSecond: Double?
    public let promptTokensPerSecond: Double?
    /// Events behind the generation figure (or the prompt figure when there is no generation one).
    public let samples: Int
}

public enum LocalRuns {
    /// Events needed before a model is reported, like the 3 calls a speed report needs.
    public static let minimumSamples = 3
    /// Reports one share may carry for local runs (the collector accepts 30 reports a batch in all).
    public static let maximumReports = 5

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Groups events by engine and shareable model name. Events from an engine on another machine, without a model, or with a model
    /// that may not be shared are ignored. A group needs `minimumSamples` timed events.
    public static func groups(events: [LocalLLMEvent], settings: LocalLLMSettings) -> [LocalRunGroup] {
        struct Key: Hashable { let backend: String; let id: String; let params: Double?; let quant: String? }
        var gen: [Key: [Double]] = [:], prompt: [Key: [Double]] = [:]
        var names: [Key: LocalModelName.Parsed] = [:]
        for event in events {
            guard let backend = LocalLLMBackend(rawValue: event.backend), LocalEngineName.isLocal(settings, backend),
                  let parsed = LocalModelName.parse(event.model) else { continue }
            let key = Key(backend: LocalEngineName.shared(event.backend), id: parsed.id, params: parsed.paramsB, quant: parsed.quant)
            names[key] = parsed
            if let seconds = event.genSeconds, seconds > 0, event.completion >= 16 { gen[key, default: []].append(event.completion / seconds) }
            let fresh = event.prompt - event.cached
            if let seconds = event.promptSeconds, seconds > 0, fresh >= 32 { prompt[key, default: []].append(fresh / seconds) }
        }
        var out: [LocalRunGroup] = []
        for key in Set(gen.keys).union(prompt.keys) {
            let samples = max(gen[key]?.count ?? 0, prompt[key]?.count ?? 0)
            guard samples >= minimumSamples, let parsed = names[key] else { continue }
            out.append(LocalRunGroup(backend: key.backend, model: parsed, genTokensPerSecond: (gen[key]?.count ?? 0) >= minimumSamples ? median(gen[key] ?? []) : nil,
                                     promptTokensPerSecond: (prompt[key]?.count ?? 0) >= minimumSamples ? median(prompt[key] ?? []) : nil, samples: samples))
        }
        return out.sorted { ($0.samples, $1.model.id, $1.backend) > ($1.samples, $0.model.id, $0.backend) }
    }

    /// The `localrun` reports for a share. Needs a chip name (nothing without one), and at most `maximumReports`.
    public static func reports(groups: [LocalRunGroup], hardware: HardwareInfo, versions: [String: String], date: String) -> [[String: Any]] {
        guard let chip = hardware.sharedChip else { return [] }
        let os = hardware.sharedOS
        return groups.prefix(maximumReports).compactMap { group -> [String: Any]? in
            guard group.genTokensPerSecond != nil || group.promptTokensPerSecond != nil else { return nil }
            var report: [String: Any] = ["type": "localrun", "localModel": group.model.id, "engine": group.backend, "chip": chip,
                                         "memGB": hardware.sharedMemoryTier, "os": os.family, "osMajor": os.major, "samples": group.samples,
                                         "date": date, "via": "quotapilot"]
            if let params = group.model.paramsB { report["paramsB"] = (params * 100).rounded() / 100 }
            if let quant = group.model.quant { report["quant"] = quant }
            if let version = versions[group.backend] { report["engineVersion"] = version }
            if let cores = hardware.sharedGPUCoreBucket, hardware.isAppleSilicon { report["gpuCores"] = cores }
            if let tps = group.genTokensPerSecond { report["genTps"] = (tps * 10).rounded() / 10 }
            if let tps = group.promptTokensPerSecond { report["promptTps"] = tps.rounded() }
            return report
        }
    }

    /// One readable line for the preview.
    public static func describe(_ report: [String: Any]) -> String {
        func number(_ key: String) -> Double? { (report[key] as? Double) ?? (report[key] as? Int).map(Double.init) }
        var model = (report["localModel"] as? String) ?? "?"
        if let params = number("paramsB") { model += " " + (params == params.rounded() ? String(Int(params)) : String(params)) + "B" }
        if let quant = report["quant"] as? String { model += " " + quant }
        var speeds: [String] = []
        if let tps = number("genTps") { speeds.append(String(format: "%.1f tok/s generation", tps)) }
        if let tps = number("promptTps") { speeds.append(String(format: "%.0f tok/s prompt", tps)) }
        let engine = ((report["engine"] as? String) ?? "?") + ((report["engineVersion"] as? String).map { " " + $0 } ?? "")
        let machine = ((report["chip"] as? String) ?? "?") + " / \(Int(number("memGB") ?? 0)) GB" + (number("gpuCores").map { " / up to \(Int($0)) GPU cores" } ?? "")
            + " / " + ((report["os"] as? String) ?? "?") + ((number("osMajor")).map { $0 > 0 ? " \(Int($0))" : "" } ?? "")
        return "local   \(model) via \(engine) on \(machine): " + speeds.joined(separator: ", ") + " (\(Int(number("samples") ?? 0)) samples)"
    }
}
