#if os(macOS)
import XCTest
@testable import UsageCore

/// Runs the real swap helper against temporary folders. `open` is replaced so nothing is launched,
/// and `mv` can be made to fail for the first call to exercise the abort path.
final class AppUpdateSwapTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func makeApp(_ path: String, marker: String) throws -> URL {
        let app = root.appendingPathComponent(path)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try marker.write(to: macOS.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        return app
    }

    func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/marker"), encoding: .utf8)
    }

    @discardableResult
    func runSwap(failFirstMove: Bool = false, failCopy: Bool = false, current: URL, staged: URL) throws -> Int32 {
        var script = AppUpdate.swapScript.replacingOccurrences(of: "/usr/bin/open", with: "probe_open")
        var prelude = "probe_open() { :; }\n"
        if failFirstMove {
            script = script.replacingOccurrences(of: "! /bin/mv \"$2\" \"$backup\"", with: "! probe_fail_mv")
            prelude += "probe_fail_mv() { return 1; }\n"
        }
        if failCopy {
            script = script.replacingOccurrences(of: "/usr/bin/ditto", with: "probe_fail_ditto")
            prelude += "probe_fail_ditto() { return 1; }\n"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", prelude + script, "probe", "999999", current.path, staged.path,
                             staged.deletingLastPathComponent().path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testSuccessfulSwapInstallsNewAppAndRemovesBackup() throws {
        let current = try makeApp("Applications/QuotaPilot.app", marker: "old")
        let staged = try makeApp("staging/QuotaPilot.app", marker: "new")
        XCTAssertEqual(try runSwap(current: current, staged: staged), 0)
        XCTAssertEqual(marker(current), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path + ".previous"))
    }

    func testFailedInitialMoveKeepsInstalledApp() throws {
        let current = try makeApp("Applications/QuotaPilot.app", marker: "old")
        let staged = try makeApp("staging/QuotaPilot.app", marker: "new")
        XCTAssertNotEqual(try runSwap(failFirstMove: true, current: current, staged: staged), 0)
        XCTAssertEqual(marker(current), "old")
    }

    func testFailedCopyRestoresBackup() throws {
        let current = try makeApp("Applications/QuotaPilot.app", marker: "old")
        let staged = try makeApp("staging/QuotaPilot.app", marker: "new")
        try runSwap(failCopy: true, current: current, staged: staged)
        XCTAssertEqual(marker(current), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path + ".previous"))
    }

    func testLeftoverBackupIsRestoredWhenAppIsMissing() throws {
        let current = root.appendingPathComponent("Applications/QuotaPilot.app")
        _ = try makeApp("Applications/QuotaPilot.app.previous", marker: "old")
        let staged = try makeApp("staging/QuotaPilot.app", marker: "new")
        XCTAssertEqual(try runSwap(current: current, staged: staged), 0)
        XCTAssertEqual(marker(current), "new")
    }
}
#endif
