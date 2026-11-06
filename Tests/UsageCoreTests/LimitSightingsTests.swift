import XCTest
@testable import UsageCore

final class LimitSightingsTests: XCTestCase {
    func testRecordKeepsFirstSeenAndLookupFindsIt() {
        var map: [String: Double] = [:]
        map = LimitSightings.record(map, windowID: "codex:primary", resetsAt: 10_000_000, now: 100)
        map = LimitSightings.record(map, windowID: "codex:primary", resetsAt: 10_000_000, now: 500)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(LimitSightings.lookup(map, windowID: "codex:primary", resetsAt: 10_000_000), 100)
        XCTAssertNil(LimitSightings.lookup(map, windowID: "claude:seven_day:primary", resetsAt: 10_000_000))
    }

    func testResetJitterAcrossAMinuteBoundaryReusesTheEntry() {
        // 9_999_989 rounds to minute 166666, 9_999_991 to 166667.
        let early = 9_999_989.0, late = 9_999_991.0
        XCTAssertNotEqual(LimitSightings.key("codex:primary", early), LimitSightings.key("codex:primary", late))
        var map = LimitSightings.record([:], windowID: "codex:primary", resetsAt: early, now: 100)
        map = LimitSightings.record(map, windowID: "codex:primary", resetsAt: late, now: 200)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(LimitSightings.lookup(map, windowID: "codex:primary", resetsAt: early), 100)
        XCTAssertEqual(LimitSightings.lookup(map, windowID: "codex:primary", resetsAt: late), 100)
    }

    func testFarResetsAndOtherWindowsAreSeparate() {
        var map = LimitSightings.record([:], windowID: "codex:primary", resetsAt: 10_000_000, now: 100)
        map = LimitSightings.record(map, windowID: "codex:primary", resetsAt: 10_000_000 + 600, now: 300)
        map = LimitSightings.record(map, windowID: "codex:secondary", resetsAt: 10_000_000, now: 400)
        XCTAssertEqual(map.count, 3)
        XCTAssertEqual(LimitSightings.lookup(map, windowID: "codex:primary", resetsAt: 10_000_000 + 600), 300)
    }

    func testPruneDropsWindowsThatHaveReset() {
        let map = [LimitSightings.key("codex:primary", 1_000): 10.0, LimitSightings.key("codex:secondary", 9_000): 20.0]
        XCTAssertEqual(Set(LimitSightings.prune(map, now: 5_000).keys), [LimitSightings.key("codex:secondary", 9_000)])
    }

    func testMergeKeepsTheEarliestTime() {
        let merged = LimitSightings.merge(["a|1": 50, "b|2": 70], with: ["a|1": 40, "c|3": 90])
        XCTAssertEqual(merged, ["a|1": 40, "b|2": 70, "c|3": 90])
    }

    func testSaveAndLoadRoundTripThroughTheStateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = LimitSightings.fileURL(in: directory)
        XCTAssertEqual(url.lastPathComponent, "limit-since.json")
        XCTAssertEqual(LimitSightings.load(from: url), [:], "a missing file is an empty map")
        let map = LimitSightings.record([:], windowID: "claude:five_hour:primary", resetsAt: 20_000, now: 77)
        XCTAssertTrue(LimitSightings.save(map, to: url))
        XCTAssertEqual(LimitSightings.load(from: url), map)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(LimitSightings.load(from: url), [:], "a damaged file is an empty map")
    }
}
