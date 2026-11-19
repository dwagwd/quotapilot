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

    func testCellarAppMapsToTheStableOptPathOnlyWhenItExists() {
        let cellar = URL(fileURLWithPath: "/opt/homebrew/Cellar/quotapilot/1.2.3/QuotaPilot.app")
        XCTAssertEqual(ProjectLinks.stableHomebrewApp(for: cellar, exists: { $0 == "/opt/homebrew/opt/quotapilot/QuotaPilot.app" })?.path, "/opt/homebrew/opt/quotapilot/QuotaPilot.app")
        XCTAssertNil(ProjectLinks.stableHomebrewApp(for: cellar, exists: { _ in false }))
        let intel = URL(fileURLWithPath: "/usr/local/Cellar/quotapilot/0.7.0/QuotaPilot.app")
        XCTAssertEqual(ProjectLinks.stableHomebrewApp(for: intel, exists: { _ in true })?.path, "/usr/local/opt/quotapilot/QuotaPilot.app")
        XCTAssertNil(ProjectLinks.stableHomebrewApp(for: URL(fileURLWithPath: "/Applications/QuotaPilot.app"), exists: { _ in true }))
        XCTAssertNil(ProjectLinks.stableHomebrewApp(for: URL(fileURLWithPath: "/opt/homebrew/Cellar/quotapilot//QuotaPilot.app"), exists: { _ in true }))
    }
}
