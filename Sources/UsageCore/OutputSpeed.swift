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
    public var tokensPerSecond: Double { seconds > 0 ? outputTokens / seconds : 0 }
}

/// Reads one log file in order and pairs each response with the request that started it.
public struct CallTimer {
    public let provider: String
    private var start: Double?
    private var pending: [String: (start: Double, end: Double, output: Double, order: Int, model: String?)] = [:]
    private var order = 0
    public static let plausibleSeconds: ClosedRange<Double> = 0.5...900

    public init(provider: String) { self.provider = provider }

    private static func json(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
    private static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

    public mutating func feed(_ line: String) -> [OutputSpeedSample] {
        provider == "codex" ? feedCodex(line) : feedClaude(line)
    }

    /// Codex: a request starts at a tool output, a user message or a new turn; `token_usage_record`
    /// is written when that response completes and carries its usage and response id.
    private mutating func feedCodex(_ line: String) -> [OutputSpeedSample] {
        let isRecord = line.contains("\"token_usage_record\"")
        guard isRecord || line.contains("_call_output\"") || line.contains("\"user_message\"") || line.contains("\"turn_context\""),
              let object = Self.json(line), let time = AgentLogParser.timestamp(object["timestamp"]) else { return [] }
        guard isRecord, object["type"] as? String == "token_usage_record" else { start = time; return [] }
        defer { start = nil }
        guard let begin = start, let payload = object["payload"] as? [String: Any],
              let usage = payload["usage"] as? [String: Any] else { return [] }
        let seconds = time - begin, output = Self.number(usage["output_tokens"])
        guard Self.plausibleSeconds.contains(seconds), output > 0 else { return [] }
        return [OutputSpeedSample(provider: "codex", timestamp: time, outputTokens: output,
                                  reasoningTokens: min(output, Self.number(usage["reasoning_output_tokens"])),
                                  seconds: seconds, key: "codex|" + ((payload["response_id"] as? String) ?? "\(time)"))]
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
        if var entry = pending[id] {
            entry.end = max(entry.end, time); entry.output = max(entry.output, output); pending[id] = entry
        } else if let begin = start {
            order += 1
            pending[id] = (begin, time, output, order, message["model"] as? String)
        }
        return []
    }

    /// Emits responses still waiting for their final block (call at the end of a read).
    public mutating func flush() -> [OutputSpeedSample] {
        let done = pending.sorted { $0.value.order < $1.value.order }.compactMap { id, entry -> OutputSpeedSample? in
            let seconds = entry.end - entry.start
            guard Self.plausibleSeconds.contains(seconds), entry.output > 0 else { return nil }
            return OutputSpeedSample(provider: AgentLogParser.providerForModel(entry.model), timestamp: entry.end, outputTokens: entry.output,
                                     reasoningTokens: 0, seconds: seconds, key: "claude|" + id)
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
