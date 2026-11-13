import XCTest
@testable import UsageCore

final class ProjectLinksTests: XCTestCase {
    func testSponsorIsHiddenUntilAnHTTPSPageExists() {
        XCTAssertNil(ProjectLinks.sponsorURL(from: ""))
        XCTAssertNil(ProjectLinks.sponsorURL(from: "http://ko-fi.com/someone"))
        XCTAssertNil(ProjectLinks.sponsorURL(from: "javascript:alert(1)"))
        XCTAssertEqual(ProjectLinks.sponsorURL(from: " https://ko-fi.com/someone ")?.host, "ko-fi.com")
    }

    func testAppBundleIsFoundOnlyFromTheHelperInsideIt() {
        let inside = URL(fileURLWithPath: "/opt/homebrew/Cellar/quotapilot/1.2.3/QuotaPilot.app/Contents/Helpers/quotapilot")
        XCTAssertEqual(ProjectLinks.appBundle(containing: inside)?.path, "/opt/homebrew/Cellar/quotapilot/1.2.3/QuotaPilot.app")
        XCTAssertNil(ProjectLinks.appBundle(containing: URL(fileURLWithPath: "/usr/local/bin/quotapilot")))
        XCTAssertNil(ProjectLinks.appBundle(containing: URL(fileURLWithPath: "/tmp/Helpers/quotapilot")))
    }
}
