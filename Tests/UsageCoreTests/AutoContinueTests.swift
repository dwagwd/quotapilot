import XCTest
@testable import UsageCore

final class AutoContinueTests: XCTestCase {
    func testResumesOnlyAfterAFreshReadingBelowTheLimit() {
        var planner = AutoContinuePlanner()
        XCTAssertEqual(planner.observe(windowID: "codex:primary", used: 80, limitReached: false, now: 0), .none)
        XCTAssertEqual(planner.observe(windowID: "codex:primary", used: 100, limitReached: false, now: 10), .none)
        XCTAssertTrue(planner.isBlocked)
        XCTAssertEqual(planner.observe(windowID: "codex:primary", used: nil, limitReached: false, now: 20), .none, "missing data is not a reset")
        XCTAssertEqual(planner.observe(windowID: "codex:primary", used: 100, limitReached: false, now: 30), .none)
        XCTAssertEqual(planner.observe(windowID: "codex:primary", used: 2, limitReached: false, now: 40), .resume(blockedSince: 10))
        XCTAssertEqual(planner.observe(windowID: "codex:primary", used: 3, limitReached: false, now: 50), .none, "resume fires once")
    }

    func testBackendLimitFlagAndOtherExhaustedWindowsBlockResume() {
        var planner = AutoContinuePlanner()
        _ = planner.observe(windowID: "codex:primary", used: 70, limitReached: true, now: 0)
        _ = planner.observe(windowID: "codex:secondary", used: 100, limitReached: false, now: 5)
        XCTAssertEqual(planner.observe(windowID: "codex:primary", used: 1, limitReached: false, now: 10), .none)
        XCTAssertEqual(planner.observe(windowID: "codex:secondary", used: 1, limitReached: false, now: 20), .resume(blockedSince: 5))
    }

    func testSessionMetaParsingSkipsSubAgents() {
        let top = #"{"timestamp":"t","type":"session_meta","payload":{"id":"abc","cwd":"/work/app","parent_thread_id":null}}"#
        XCTAssertEqual(CodexSessionLocator.reference(firstLine: top, modifiedAt: 5), CodexSessionReference(id: "abc", cwd: "/work/app", modifiedAt: 5))
        let sub = #"{"type":"session_meta","payload":{"id":"def","cwd":"/work/app","parent_thread_id":"abc"}}"#
        XCTAssertNil(CodexSessionLocator.reference(firstLine: sub, modifiedAt: 5))
        XCTAssertNil(CodexSessionLocator.reference(firstLine: #"{"type":"response_item"}"#, modifiedAt: 5))
    }

    func testInterruptedSessionPicksNewestActiveTopLevelSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let day = root.appendingPathComponent("2026/10/15")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, id: String, parent: String?, modified: Double) throws {
            let url = day.appendingPathComponent(name)
            let parentJSON = parent.map { "\"\($0)\"" } ?? "null"
            try (#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/w/\#(id)","parent_thread_id":\#(parentJSON)}}"# + "\n{}\n")
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
        }
        try write("old.jsonl", id: "old", parent: nil, modified: 1_000)
        try write("main.jsonl", id: "main", parent: nil, modified: 10_000)
        try write("sub.jsonl", id: "sub", parent: "main", modified: 10_100)
        let found = CodexSessionLocator.interruptedSession(root: root, blockedSince: 10_050, now: 20_000)
        XCTAssertEqual(found?.id, "main")
        XCTAssertEqual(found?.cwd, "/w/main")
        XCTAssertNil(CodexSessionLocator.interruptedSession(root: root, blockedSince: 50_000, now: 60_000))
    }
}
