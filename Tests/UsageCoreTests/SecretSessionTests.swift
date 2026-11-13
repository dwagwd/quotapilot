import XCTest
@testable import UsageCore

final class SecretSessionTests: XCTestCase {
    func testRequestsWithLoginsAreNeverCachedOrStored() {
        let config = SecretSession.configuration
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }
}
