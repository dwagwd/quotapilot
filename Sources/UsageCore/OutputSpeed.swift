import Foundation

/// One model call's output speed: output tokens (including hidden reasoning) over the call's wall time,
/// from the request (prompt or tool result) to the end of the response. Because that time also includes
/// prefill, time to first token and network, this is a lower bound on decode (TG) tokens per second.
public struct OutputSpeedSample: Equatable {
    public let provider: String
    public let timestamp: Double
    public let outputTokens: Double
    public let reasoningTokens: Double
    public let seconds: Double
    public let key: String
    /// Model that produced the response, when the log names it.
    public var model: String? = nil
    /// Reasoning effort the call ran at (`low` … `max`), when the log names it.
    public var effort: String? = nil
    /// Prompt side of the call: new input, input read from the prompt cache, and input written to it.
    public var inputTokens: Double = 0
    public var cacheReadTokens: Double = 0
    public var cacheWriteTokens: Double = 0
    public var tokensPerSecond: Double { seconds > 0 ? outputTokens / seconds : 0 }
}

/// Reads one log file in order and pairs each response with the request that started it.
public struct CallTimer {
    public let provider: String
    private var start: Double?
    private var codexModel: String?
    private var codexEffort: String?
    private var pending: [String: (start: Double, end: Double, output: Double, order: Int, model: String?, effort: String?, reasoning: Double, input: Double, cacheRead: Double, cacheWrite: Double)] = [:]
    private var order = 0
    public static let plausibleSeconds: ClosedRange<Double> = 0.5...900

    public init(provider: String) { self.provider = provider }

    private static func json(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
    private static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

    public mutating func feed(_ line: String) -> [OutputSpeedSample] {
        switch provider {
        case "codex": return feedCodex(line)
        case "gemini": return feedGemini(line)
        case "grok": return []  // the Grok log has no request start time
        default: return feedClaude(line)
        }
    }

    /// Codex: a request starts at a tool output, a user message or a new turn; `token_usage_record`
    /// is written when that response completes and carries its usage and response id.
    private mutating func feedCodex(_ line: String) -> [OutputSpeedSample] {
        let isRecord = line.contains("\"token_usage_record\"")
        guard isRecord || line.contains("_call_output\"") || line.contains("\"user_message\"") || line.contains("\"turn_context\""),
              let object = Self.json(line), let time = AgentLogParser.timestamp(object["timestamp"]) else { return [] }
        if object["type"] as? String == "turn_context", let payload = object["payload"] as? [String: Any], let model = payload["model"] as? String {
            codexModel = model
            let mode = (payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
            codexEffort = (payload["effort"] as? String) ?? (mode?["reasoning_effort"] as? String)
        }
        guard isRecord, object["type"] as? String == "token_usage_record" else { start = time; return [] }
        defer { start = nil }
        guard let begin = start, let payload = object["payload"] as? [String: Any],
              let usage = payload["usage"] as? [String: Any] else { return [] }
        let seconds = time - begin, output = Self.number(usage["output_tokens"])
        guard Self.plausibleSeconds.contains(seconds), output > 0 else { return [] }
        var sample = OutputSpeedSample(provider: "codex", timestamp: time, outputTokens: output,
                                       reasoningTokens: min(output, Self.number(usage["reasoning_output_tokens"])),
                                       seconds: seconds, key: "codex|" + ((payload["response_id"] as? String) ?? "\(time)"),
                                       model: (payload["model"] as? String) ?? codexModel, effort: codexEffort)
        // Codex counts cached input inside input_tokens.
        let cached = Self.number(usage["cached_input_tokens"]), written = Self.number(usage["cache_write_input_tokens"])
        sample.inputTokens = max(0, Self.number(usage["input_tokens"]) - cached - written)
        sample.cacheReadTokens = cached
        sample.cacheWriteTokens = written
        return [sample]
    }

    /// Gemini CLI: a `user` message (prompt or tool result) starts a request; the `gemini` message with
    /// `tokens` ends it. Re-written messages keep their id and are counted once.
    private var geminiSeen = Set<String>()
    private mutating func feedGemini(_ line: String) -> [OutputSpeedSample] {
        let isUser = line.contains("\"type\":\"user\""), isModel = line.contains("\"type\":\"gemini\"")
        guard isUser || isModel, let object = Self.json(line), let time = AgentLogParser.timestamp(object["timestamp"]) else { return [] }
        if object["type"] as? String == "user" { start = time; return [] }
        guard object["type"] as? String == "gemini", let tokens = object["tokens"] as? [String: Any], let begin = start else { return [] }
        let id = (object["id"] as? String) ?? "\(time)"
        guard geminiSeen.insert(id).inserted else { return [] }
        start = nil
        let thoughts = Self.number(tokens["thoughts"]), output = Self.number(tokens["output"]) + thoughts
        let seconds = time - begin
        guard Self.plausibleSeconds.contains(seconds), output > 0 else { return [] }
        var sample = OutputSpeedSample(provider: "gemini", timestamp: time, outputTokens: output, reasoningTokens: thoughts,
                                       seconds: seconds, key: "gemini|" + id, model: object["model"] as? String, effort: nil)
        let cached = Self.number(tokens["cached"])
        sample.inputTokens = max(0, Self.number(tokens["input"]) - cached) + Self.number(tokens["tool"])
        sample.cacheReadTokens = cached
        return [sample]
    }

    /// Claude Code: a `user` line (prompt or tool result) starts a request; the assistant message is written
    /// block by block with the same id, and its last block marks the end of the response.
    private mutating func feedClaude(_ line: String) -> [OutputSpeedSample] {
        let isUser = line.contains("\"type\":\"user\""), isAssistant = line.contains("\"type\":\"assistant\"")
        guard isUser || isAssistant, let object = Self.json(line), let time = AgentLogParser.timestamp(object["timestamp"]) else { return [] }
        if object["type"] as? String == "user" {
            let done = flush()
            start = time
            return done
        }
        guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
              let id = message["id"] as? String, let usage = message["usage"] as? [String: Any] else { return [] }
        let output = Self.number(usage["output_tokens"])
        let thinking = Self.number((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
        let input = Self.number(usage["input_tokens"]), cacheRead = Self.number(usage["cache_read_input_tokens"])
        let cacheWrite = Self.number(usage["cache_creation_input_tokens"])
        if var entry = pending[id] {
            entry.end = max(entry.end, time); entry.output = max(entry.output, output); entry.reasoning = max(entry.reasoning, thinking)
            entry.input = max(entry.input, input); entry.cacheRead = max(entry.cacheRead, cacheRead); entry.cacheWrite = max(entry.cacheWrite, cacheWrite)
            pending[id] = entry
        } else if let begin = start {
            order += 1
            pending[id] = (begin, time, output, order, message["model"] as? String, object["effort"] as? String, thinking, input, cacheRead, cacheWrite)
        }
        return []
    }

    /// Emits responses still waiting for their final block (call at the end of a read).
    public mutating func flush() -> [OutputSpeedSample] {
        let done = pending.sorted { $0.value.order < $1.value.order }.compactMap { id, entry -> OutputSpeedSample? in
            let seconds = entry.end - entry.start
            guard Self.plausibleSeconds.contains(seconds), entry.output > 0 else { return nil }
            var sample = OutputSpeedSample(provider: AgentLogParser.providerForModel(entry.model), timestamp: entry.end, outputTokens: entry.output,
                                           reasoningTokens: min(entry.output, entry.reasoning), seconds: seconds, key: "claude|" + id,
                                           model: entry.model, effort: entry.effort)
            sample.inputTokens = entry.input; sample.cacheReadTokens = entry.cacheRead; sample.cacheWriteTokens = entry.cacheWrite
            return sample
        }
        pending = [:]
        return done
    }
}

/// Aggregate output speed: total output tokens over total call time, plus the median call.
public struct OutputSpeedSummary: Equatable {
    public let calls: Int
    public let outputTokens: Double
    public let seconds: Double
    public let medianTokensPerSecond: Double
    public var tokensPerSecond: Double { seconds > 0 ? outputTokens / seconds : 0 }

    public init?(_ samples: [OutputSpeedSample]) {
        guard !samples.isEmpty else { return nil }
        calls = samples.count
        outputTokens = samples.reduce(0) { $0 + $1.outputTokens }
        seconds = samples.reduce(0) { $0 + $1.seconds }
        let speeds = samples.map(\.tokensPerSecond).sorted()
        medianTokensPerSecond = speeds.count % 2 == 1 ? speeds[speeds.count / 2] : (speeds[speeds.count / 2 - 1] + speeds[speeds.count / 2]) / 2
    }
}
