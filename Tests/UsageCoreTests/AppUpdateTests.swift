import XCTest
@testable import UsageCore

final class AppUpdateTests: XCTestCase {
    func release(_ tag: String, assets: [(String, String)], digest: String? = nil, prerelease: Bool = false) -> Data {
        let list = assets.map { name, url -> [String: Any] in
            var a: [String: Any] = ["name": name, "browser_download_url": url]
            if let digest { a["digest"] = digest }
            return a
        }
        let object: [String: Any] = ["tag_name": tag, "html_url": "https://github.com/dwagwd/quotapilot/releases/tag/\(tag)", "prerelease": prerelease, "draft": false, "assets": list]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testPicksTheZipForThisMachine() throws {
        let data = release("v0.6.0", assets: [("QuotaPilot-0.6.0-source.zip", "https://github.com/a/b/source.zip"),
                                              ("QuotaPilot-0.6.0-macos-universal.zip", "https://github.com/a/b/u.zip"),
                                              ("QuotaPilot-0.6.0-macos-arm64.zip", "https://github.com/a/b/arm.zip")], digest: "sha256:ABCD")
        let r = try XCTUnwrap(AppUpdate.parse(data, arch: "arm64"))
        XCTAssertEqual(r.version, "0.6.0")
        XCTAssertEqual(r.assetName, "QuotaPilot-0.6.0-macos-arm64.zip")
        XCTAssertEqual(r.sha256, "abcd")
        XCTAssertEqual(AppUpdate.parse(data, arch: "x86_64")?.assetName, "QuotaPilot-0.6.0-macos-universal.zip")
    }

    func testRefusesPrereleasesAndForeignHosts() {
        XCTAssertNil(AppUpdate.parse(release("v0.6.0", assets: [("QuotaPilot-0.6.0-macos-arm64.zip", "https://github.com/a/b/x.zip")], prerelease: true), arch: "arm64"))
        XCTAssertNil(AppUpdate.parse(release("v0.6.0", assets: [("QuotaPilot-0.6.0-macos-arm64.zip", "https://evil.example/x.zip")]), arch: "arm64"))
        XCTAssertNil(AppUpdate.parse(release("v0.6.0", assets: [("QuotaPilot-0.6.0-macos-arm64.zip", "http://github.com/a/b/x.zip")]), arch: "arm64"))
    }

    func testRefusesPathLikeTagsAndAssetNames() {
        XCTAssertNil(AppUpdate.parse(release("v99.0.0/../../../..", assets: [("QuotaPilot-99.0.0-macos-arm64.zip", "https://github.com/a/b/x.zip")]), arch: "arm64"))
        XCTAssertNil(AppUpdate.parse(release("v0.6.0", assets: [("QuotaPilot-../../x-macos-arm64.zip", "https://github.com/a/b/x.zip")]), arch: "arm64"))
        XCTAssertNil(AppUpdate.parse(release("v0.6.0", assets: [("QuotaPilot-a/b-macos-arm64.zip", "https://github.com/a/b/x.zip")]), arch: "arm64"))
        XCTAssertNotNil(AppUpdate.parse(release("v0.6.0-beta.1", assets: [("QuotaPilot-0.6.0-beta.1-macos-arm64.zip", "https://github.com/a/b/x.zip")]), arch: "arm64"))
        XCTAssertTrue(AppUpdate.isSafeVersion("0.10.2+12"))
        XCTAssertFalse(AppUpdate.isSafeVersion("0.1/../x"))
        XCTAssertFalse(AppUpdate.isSafeVersion(""))
    }

    func testVersionOrder() {
        XCTAssertTrue(AppUpdate.isNewer("0.10.0", than: "0.9.2"))
        XCTAssertTrue(AppUpdate.isNewer("0.5.1", than: "0.5.0"))
        XCTAssertFalse(AppUpdate.isNewer("0.5.0", than: "0.5.0+12"))
        XCTAssertFalse(AppUpdate.isNewer("0.4.9", than: "0.5"))
    }

    func testShareHelpers() {
        XCTAssertEqual(ContributionReport.sharedProvider(windowID: "codex:primary"), "codex")
        XCTAssertEqual(ContributionReport.sharedProvider(windowID: "claude:seven_day:primary"), "claude")
        XCTAssertNil(ContributionReport.sharedProvider(windowID: "claude:seven_day_opus:primary"))
        XCTAssertNil(ContributionReport.sharedProvider(windowID: "codex_spark:primary"))
        let text = ContributionReport.issueText(reports: [["type": "speed"]], version: "0.6.0")
        XCTAssertTrue(text.body.hasPrefix(ContributionReport.issueMarker))
        XCTAssertTrue(text.body.contains("```json"))
        var settings = WidgetSettings()
        XCTAssertTrue(settings.updateChecksEnabled)
        XCTAssertFalse(settings.autoShareEnabled, "sharing is off until the user turns it on")
        settings.autoShareEnabled = true
        XCTAssertTrue(settings.autoShareEnabled)
    }

    func testInstallIDIsStableAndBodyCarriesNoAccount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qp-install-\(UUID().uuidString)")
        let a = ShareSubmitter.installID(directory: dir), b = ShareSubmitter.installID(directory: dir)
        XCTAssertEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.count, 16)
        let body = try XCTUnwrap(ShareSubmitter.anonymousBody(reports: [["type": "speed"]], install: a))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["install", "reports"])
        try? FileManager.default.removeItem(at: dir)
    }
}
