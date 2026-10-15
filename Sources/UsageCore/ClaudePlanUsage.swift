import Foundation
import CryptoKit

/// Claude subscription (Pro/Max) usage from the endpoint Claude Code itself uses:
/// `GET https://api.anthropic.com/api/oauth/usage` with the user's Claude Code login.
/// Converted into the same sanitized provider snapshot the status-line bridge writes.
public enum ClaudePlanUsage {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"

    private static let windows: [(key: String, name: String, minutes: Int)] = [
        ("five_hour", "Claude", 300), ("seven_day", "Claude", 10080),
        ("seven_day_opus", "Claude Opus", 10080), ("seven_day_sonnet", "Claude Sonnet", 10080)
    ]

    /// Access token and plan from Claude Code's stored credentials JSON (`claudeAiOauth`).
    public static func credentials(from data: Data) -> (token: String, plan: String?, expiresAt: Double?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { $0.doubleValue / 1000 }
        return (token, oauth["subscriptionType"] as? String, expires)
    }

    public static func snapshot(from data: Data, plan: String?, now: Double) -> ProviderSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var buckets: [String: Bucket] = [:]
        for window in windows {
            guard let entry = object[window.key] as? [String: Any],
                  let used = (entry["utilization"] as? NSNumber)?.doubleValue, used.isFinite else { continue }
            let reset = AgentLogParser.timestamp(entry["resets_at"])
            buckets["claude:" + window.key] = Bucket(limitId: "claude:" + window.key, limitName: window.name, planType: plan,
                                                    primary: QuotaWindow(usedPercent: min(max(used, 0), 100), windowDurationMins: window.minutes, resetsAt: reset),
                                                    secondary: nil)
        }
        guard !buckets.isEmpty else { return nil }
        let identity = SHA256.hash(data: Data(("claude-plan:" + (plan ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
        return ProviderSnapshot(provider: "claude", account: identity, updatedAt: now,
                                limits: LimitsResponse(rateLimits: nil, rateLimitsByLimitId: buckets, accountId: nil))
    }
}
