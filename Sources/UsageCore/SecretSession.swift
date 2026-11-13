import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Network session for requests that carry a login or API key (Claude plan usage, DeepSeek balance).
/// `URLSession.shared` stores responses, and the request with its Authorization header, in the app's
/// Cache.db under ~/Library/Caches, so a Claude Code token or DeepSeek key would end up on disk. This session
/// keeps nothing: no URL cache, no cookies, no credential storage.
public enum SecretSession {
    public static let configuration: URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return config
    }()
    public static let shared = URLSession(configuration: configuration)

    /// Removes responses that older versions stored through `URLSession.shared`, including the cached
    /// requests to api.anthropic.com and api.deepseek.com with their Authorization headers.
    public static func purgeSharedCache() {
        URLCache.shared.removeAllCachedResponses()
    }
}
