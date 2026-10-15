import Foundation

/// DeepSeek's prepaid API balance (`GET https://api.deepseek.com/user/balance`). DeepSeek has no plan quota
/// or reset window, so the balance is shown as an amount, never as a percentage.
public struct DeepSeekBalance: Equatable {
    public let currency: String
    public let total: Double
    public let granted: Double?
    public let toppedUp: Double?

    public static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    public static func parse(_ data: Data) -> (available: Bool, balances: [DeepSeekBalance])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = object["balance_infos"] as? [[String: Any]] else { return nil }
        func amount(_ value: Any?) -> Double? {
            if let text = value as? String, let number = Double(text), number.isFinite { return number }
            if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
            return nil
        }
        let balances = infos.compactMap { info -> DeepSeekBalance? in
            guard let currency = info["currency"] as? String, !currency.isEmpty, let total = amount(info["total_balance"]) else { return nil }
            return DeepSeekBalance(currency: currency, total: total, granted: amount(info["granted_balance"]), toppedUp: amount(info["topped_up_balance"]))
        }
        return (object["is_available"] as? Bool ?? !balances.isEmpty, balances)
    }
}

extension DeepSeekBalance {
    /// The token Claude Code uses when its Anthropic-compatible base URL is DeepSeek's; nil for any other endpoint.
    public static func key(fromClaudeSettings data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any],
              let base = env["ANTHROPIC_BASE_URL"] as? String,
              let host = URL(string: base)?.host?.lowercased(),
              host == "deepseek.com" || host.hasSuffix(".deepseek.com") else { return nil }
        let key = (env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? (env["ANTHROPIC_API_KEY"] as? String)
        return key?.isEmpty == false ? key : nil
    }
}
