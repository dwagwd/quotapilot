import XCTest
@testable import UsageCore

final class ClaudeLoginCacheTests: XCTestCase {
    private func creds(_ token: String, expires: Double?) -> Data {
        let expiry = expires.map { ",\"expiresAt\":\(Int($0 * 1000))" } ?? ""
        return Data("{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"\(expiry),\"subscriptionType\":\"max\"}}".utf8)
    }

    private final class Env {
        var now = 1_000_000.0
        var file: Data?
        var keychain: Data?
        var keychainDenied = false
        var stamp: String? = "v1"
        var reads = 0
    }

    private func make(_ env: Env) -> ClaudeLoginCache {
        ClaudeLoginCache(readFile: { env.file },
                         readKeychain: { env.reads += 1; return env.keychainDenied ? nil : env.keychain },
                         keychainStamp: { env.stamp }, now: { env.now })
    }

    func testReadsKeychainOnceUntilTokenExpires() {
        let env = Env(); env.keychain = creds("a", expires: env.now + 8 * 3600)
        let cache = make(env)
        for _ in 0..<50 { env.now += 120; XCTAssertEqual(cache.login(), .login(ClaudeLogin(token: "a", plan: "max", expiresAt: 1_000_000 + 8 * 3600))) }
        XCTAssertEqual(env.reads, 1)
    }

    func testExpiredTokenIsNotReadAgainUntilClaudeCodeWritesTheItem() {
        let env = Env(); env.keychain = creds("a", expires: env.now + 3600)
        let cache = make(env)
        _ = cache.login()
        env.now += 7200
        for _ in 0..<20 { XCTAssertEqual(cache.login(), .expired); env.now += 120 }
        XCTAssertEqual(env.reads, 1, "an unchanged item still holds the expired token")
        env.keychain = creds("b", expires: env.now + 8 * 3600); env.stamp = "v2"
        guard case .login(let login) = cache.login() else { return XCTFail("new token expected") }
        XCTAssertEqual(login.token, "b"); XCTAssertEqual(env.reads, 2)
    }

    func testRefreshedItemIsNotReadWhileTheCachedTokenIsValid() {
        let env = Env(); env.keychain = creds("a", expires: env.now + 8 * 3600)
        let cache = make(env)
        _ = cache.login()
        env.keychain = creds("b", expires: env.now + 16 * 3600); env.stamp = "v2"   // Claude Code refreshed it
        env.now += 3600
        guard case .login(let login) = cache.login() else { return XCTFail() }
        XCTAssertEqual(login.token, "a"); XCTAssertEqual(env.reads, 1)
    }

    func testUnauthorizedTokenIsOnlyReplacedByANewItem() {
        let env = Env(); env.keychain = creds("a", expires: nil)
        let cache = make(env)
        _ = cache.login(); cache.reject()
        XCTAssertEqual(cache.login(), .expired); XCTAssertEqual(env.reads, 1)
        env.keychain = creds("b", expires: nil); env.stamp = "v2"
        XCTAssertEqual(cache.login(), .login(ClaudeLogin(token: "b", plan: "max", expiresAt: nil)))
    }

    func testDeniedReadBacksOffThenRetriesOnRequest() {
        let env = Env(); env.keychainDenied = true
        let cache = make(env)
        XCTAssertEqual(cache.login(), .needsAccess)
        for _ in 0..<100 { env.now += 120; if env.now - 1_000_000 < ClaudeLoginCache.backoff { XCTAssertEqual(cache.login(), .needsAccess) } }
        XCTAssertEqual(env.reads, 1)
        env.keychainDenied = false; env.keychain = creds("a", expires: nil)
        cache.retryNow()
        XCTAssertEqual(cache.login(), .login(ClaudeLogin(token: "a", plan: "max", expiresAt: nil)))
        XCTAssertEqual(env.reads, 2)
    }

    func testBackoffEndsAfterHours() {
        let env = Env(); env.keychainDenied = true
        let cache = make(env)
        _ = cache.login()
        env.now += ClaudeLoginCache.backoff - 1
        XCTAssertEqual(cache.login(), .needsAccess); XCTAssertEqual(env.reads, 1)
        env.now += 2
        _ = cache.login(); XCTAssertEqual(env.reads, 2)
    }

    func testCredentialsFileWinsAndNeverTouchesTheKeychain() {
        let env = Env(); env.file = creds("file", expires: env.now + 3600); env.keychain = creds("kc", expires: nil)
        let cache = make(env)
        XCTAssertEqual(cache.login(), .login(ClaudeLogin(token: "file", plan: "max", expiresAt: 1_000_000 + 3600)))
        XCTAssertEqual(env.reads, 0)
    }

    func testMissingItemAndForget() {
        let env = Env(); env.stamp = nil
        let cache = make(env)
        XCTAssertEqual(cache.login(), .missing); XCTAssertEqual(env.reads, 0)
        env.stamp = "v1"; env.keychain = creds("a", expires: nil)
        _ = cache.login(); cache.forget(); _ = cache.login()
        XCTAssertEqual(env.reads, 2)
    }

    func testBridgeFreshnessNeedsASnapshotNewerThanThePlanMarker() {
        let now = 10_000.0
        XCTAssertTrue(ClaudeBridgeSource.isFresh(snapshotModified: now - 60, planMarkerModified: nil, now: now))
        XCTAssertTrue(ClaudeBridgeSource.isFresh(snapshotModified: now - 60, planMarkerModified: now - 900, now: now))
        XCTAssertFalse(ClaudeBridgeSource.isFresh(snapshotModified: now - 60, planMarkerModified: now - 60, now: now), "written by the plan request")
        XCTAssertFalse(ClaudeBridgeSource.isFresh(snapshotModified: now - 400, planMarkerModified: nil, now: now), "older than five minutes")
        XCTAssertFalse(ClaudeBridgeSource.isFresh(snapshotModified: nil, planMarkerModified: nil, now: now))
    }

    func testKeychainAttributesYieldTheModificationStamp() {
        let text = "keychain: \"~/Library/Keychains/login.keychain-db\"\nattributes:\n    \"cdat\"<timedate>=0x3230  \"20260920020404Z\\000\"\n    \"mdat\"<timedate>=0x3230  \"20261126002409Z\\000\"\n    \"svce\"<blob>=\"Claude Code-credentials\"\n"
        XCTAssertEqual(ClaudeKeychain.stampValue(fromAttributes: text), "20261126002409Z")
    }
}
