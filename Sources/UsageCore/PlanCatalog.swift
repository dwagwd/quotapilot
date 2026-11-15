import Foundation

/// Subscription plan names for the coding agents QuotaPilot watches. Raw ids come from each tool's own
/// sign-in data (Codex `plan_type`, Claude Code `subscriptionType` + `rateLimitTier`, Gemini CLI auth type);
/// this maps them to the plan names users see on the vendors' pricing pages.
/// Sources (checked 2026-11-15): learn.chatgpt.com/docs/pricing (Codex), support.claude.com (Claude plans),
/// docs.cloud.google.com/gemini/docs/quotas + geminicli.com quota page (Gemini).
public enum PlanCatalog {
    /// Official display name for a raw plan id, or nil when the id is empty.
    public static func displayName(provider: String?, raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let key = raw.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        if let provider, let known = names[provider + ":" + key] { return known }
        if let known = names[key] { return known }
        return ContributionReport.planName(raw)
    }

    private static let names: [String: String] = [
        // ChatGPT / Codex
        "free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro 5x", "pro_lite": "Pro 5x",
        "pro_5x": "Pro 5x", "pro_20x": "Pro 20x", "team": "Business", "business": "Business", "self_serve_business_usage_based": "Business",
        "enterprise": "Enterprise", "edu": "Edu", "education": "Edu", "k12": "Edu",
        // Claude (`pro` is Claude Pro, not ChatGPT Pro, so it is keyed by provider below)
        "claude:pro": "Pro", "max": "Max", "max_5x": "Max 5x", "max_20x": "Max 20x",
        "claude:team": "Team", "claude:enterprise": "Enterprise",
        // Google (Gemini CLI / Antigravity / Code Assist)
        "oauth_personal": "Google account (Free / AI Pro / AI Ultra)", "gemini_api_key": "Gemini API key",
        "vertex_ai": "Vertex AI", "compute_adc": "Google Cloud",
        "google_ai_pro": "Google AI Pro", "google_ai_ultra": "Google AI Ultra",
        "free_tier": "Gemini Code Assist (Free)", "standard_tier": "Gemini Code Assist Standard",
        "enterprise_tier": "Gemini Code Assist Enterprise", "legacy_tier": "Gemini Code Assist (Legacy)"
    ]

    /// Plans each provider sells today, for the plan picker and reference table. `perFiveHours` / `perDay` are
    /// the vendor's published numbers; nil where the vendor publishes none (never guessed).
    public struct Plan: Equatable {
        public let provider: String
        public let id: String
        public let name: String
        public let note: String
    }

    public static let plans: [Plan] = [
        Plan(provider: "codex", id: "free", name: "ChatGPT Free", note: "limited Codex access"),
        Plan(provider: "codex", id: "go", name: "ChatGPT Go", note: "no published Codex numbers"),
        Plan(provider: "codex", id: "plus", name: "ChatGPT Plus", note: "5h window + weekly cap; ~15-160 local messages/5h on GPT-6.1 Sol"),
        Plan(provider: "codex", id: "pro_5x", name: "ChatGPT Pro 5x", note: "$100; no five-hour limit per OpenAI pricing page"),
        Plan(provider: "codex", id: "pro_20x", name: "ChatGPT Pro 20x", note: "$200; no five-hour limit per OpenAI pricing page"),
        Plan(provider: "codex", id: "business", name: "ChatGPT Business", note: "same per-seat limits as Plus"),
        Plan(provider: "codex", id: "enterprise", name: "ChatGPT Enterprise / Edu", note: "credit pool, or Plus-like per-seat limits"),
        Plan(provider: "claude", id: "pro", name: "Claude Pro", note: "baseline 1x; 5h window + weekly cap"),
        Plan(provider: "claude", id: "max_5x", name: "Claude Max 5x", note: "5x Pro usage"),
        Plan(provider: "claude", id: "max_20x", name: "Claude Max 20x", note: "20x Pro usage"),
        Plan(provider: "claude", id: "team", name: "Claude Team", note: "Standard / Premium seats"),
        Plan(provider: "claude", id: "enterprise", name: "Claude Enterprise", note: "seat or usage based"),
        Plan(provider: "gemini", id: "free_tier", name: "Gemini free (Google account)", note: "1,000 requests/day"),
        Plan(provider: "gemini", id: "google_ai_pro", name: "Google AI Pro", note: "1,500 requests/day"),
        Plan(provider: "gemini", id: "google_ai_ultra", name: "Google AI Ultra", note: "2,000 requests/day"),
        Plan(provider: "gemini", id: "standard_tier", name: "Gemini Code Assist Standard", note: "1,500 requests/user/day"),
        Plan(provider: "gemini", id: "enterprise_tier", name: "Gemini Code Assist Enterprise", note: "2,000 requests/user/day")
    ]

    /// What Gemini CLI says about the sign-in in `~/.gemini/settings.json` (`security.auth.selectedType`, or the
    /// older top-level `selectedAuthType`). The Google plan itself (Free / AI Pro / AI Ultra) is not stored on
    /// disk, so this only separates a Google account from an API key or Google Cloud.
    public static func geminiAuthType(settings: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any] else { return nil }
        let nested = ((object["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String
        guard let raw = nested ?? object["selectedAuthType"] as? String, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "-", with: "_")
    }
}
