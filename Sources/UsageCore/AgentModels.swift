import Foundation

/// A model observation from a local agent log: what was requested, what answered, or a server-side reroute.
public struct AgentModelEvent: Equatable {
    public enum Kind: String, Codable { case requested, served, rerouted }
    public let provider: String
    public let timestamp: Double
    public let kind: Kind
    public let model: String
    /// For `rerouted`: the model that was asked for.
    public let fromModel: String?
    public let effort: String?
    public let reason: String?
    public init(provider: String, timestamp: Double, kind: Kind, model: String, fromModel: String?, effort: String?, reason: String?) {
        self.provider = provider; self.timestamp = timestamp; self.kind = kind; self.model = model
        self.fromModel = fromModel; self.effort = effort; self.reason = reason
    }
}

extension AgentLogParser {
    private static func object(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    private static func describe(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text.isEmpty ? nil : text
        case let map as [String: Any]: return (map["type"] as? String) ?? map.keys.sorted().first
        default: return nil
        }
    }

    /// Codex rollout lines: `turn_context` (requested model and reasoning effort) and the
    /// `model_reroute` event Codex emits when the server answers with a different model than requested.
    public static func codexModelEvent(_ line: String) -> AgentModelEvent? {
        guard line.contains("\"turn_context\"") || line.contains("\"model_reroute\""),
              let object = object(line), let time = timestamp(object["timestamp"]),
              let payload = object["payload"] as? [String: Any] else { return nil }
        if object["type"] as? String == "turn_context", let model = payload["model"] as? String, !model.isEmpty {
            return AgentModelEvent(provider: "codex", timestamp: time, kind: .requested, model: model, fromModel: nil,
                                   effort: payload["effort"] as? String, reason: nil)
        }
        if payload["type"] as? String == "model_reroute" {
            let to = (payload["to_model"] as? String) ?? (payload["model"] as? String) ?? "unknown"
            return AgentModelEvent(provider: "codex", timestamp: time, kind: .rerouted, model: to,
                                   fromModel: payload["from_model"] as? String, effort: nil, reason: describe(payload["reason"]))
        }
        return nil
    }

    /// Claude Code lines: the model that actually produced each assistant message.
    public static func claudeModelEvent(_ line: String) -> AgentModelEvent? {
        guard line.contains("\"assistant\""), line.contains("\"model\""),
              let object = object(line), object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let model = message["model"] as? String, !model.isEmpty, !model.hasPrefix("<"),
              let time = timestamp(object["timestamp"]) else { return nil }
        return AgentModelEvent(provider: providerForModel(model), timestamp: time, kind: .served, model: model,
                               fromModel: nil, effort: nil, reason: nil)
    }
}

/// Latest model per agent and recent reroutes.
public struct AgentModelTracker {
    public struct Current: Equatable {
        public var model: String
        public var effort: String?
        public var at: Double
    }
    public private(set) var current: [String: Current] = [:]
    public private(set) var reroutes: [AgentModelEvent] = []
    public init() {}

    /// Returns true when the event is a reroute not seen before.
    @discardableResult
    public mutating func observe(_ event: AgentModelEvent) -> Bool {
        if event.kind == .rerouted {
            guard !reroutes.contains(event) else { return false }
            reroutes.append(event)
            reroutes.sort { $0.timestamp < $1.timestamp }
            if reroutes.count > 50 { reroutes.removeFirst(reroutes.count - 50) }
            return true
        }
        if let existing = current[event.provider], existing.at > event.timestamp { return false }
        current[event.provider] = Current(model: event.model, effort: event.effort ?? (event.kind == .served ? nil : current[event.provider]?.effort), at: event.timestamp)
        return false
    }

    public func recentReroutes(provider: String, since: Double) -> [AgentModelEvent] {
        reroutes.filter { $0.provider == provider && $0.timestamp >= since }
    }
}
