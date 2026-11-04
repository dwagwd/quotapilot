import XCTest
@testable import UsageCore

final class AutoContinueTests: XCTestCase {
    func testResumesOnlyAfterAFreshReadingBelowTheLimit() {
        var planner = AutoContinuePlanner()
        XCTAssertEqual(planner.observe(windowID: "codex:primary", used: 80, limitReached: false, now: 0), .none)
        XCTAssertEqual(planner.observe(windowID: "codex:primary", used: 100, limitReached: false, now: 10), .blocked(since: 10))
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
        XCTAssertEqual(planner.observe(windowID: "codex:secondary", used: 1, limitReached: false, now: 20), .resume(blockedSince: 0))
    }

    func testSessionMetaParsingSkipsSubAgents() {
        let top = #"{"timestamp":"t","type":"session_meta","payload":{"id":"abc","cwd":"/work/app","parent_thread_id":null}}"#
        XCTAssertEqual(CodexSessionLocator.reference(firstLine: top, modifiedAt: 5), CodexSessionReference(id: "abc", cwd: "/work/app", modifiedAt: 5))
        let sub = #"{"type":"session_meta","payload":{"id":"def","cwd":"/work/app","parent_thread_id":"abc"}}"#
        XCTAssertNil(CodexSessionLocator.reference(firstLine: sub, modifiedAt: 5))
        XCTAssertNil(CodexSessionLocator.reference(firstLine: #"{"type":"response_item"}"#, modifiedAt: 5))
    }

    func testWholeResponseIsCheckedBeforeResuming() {
        typealias W = AutoContinuePlanner.Window
        var planner = AutoContinuePlanner()
        XCTAssertEqual(planner.observe(windows: [W(id: "p", used: 100, limitReached: true), W(id: "s", used: 60, limitReached: false)], account: "a", now: 10), .blocked(since: 10))
        // Primary resets while secondary becomes exhausted in the same response: no resume.
        XCTAssertEqual(planner.observe(windows: [W(id: "p", used: 0, limitReached: false), W(id: "s", used: 100, limitReached: false)], account: "a", now: 20), .none)
        XCTAssertTrue(planner.isBlocked)
        // A response with a missing reading is not fresh enough.
        XCTAssertEqual(planner.observe(windows: [W(id: "p", used: 1, limitReached: false), W(id: "s", used: nil, limitReached: false)], account: "a", now: 25), .none)
        XCTAssertEqual(planner.observe(windows: [W(id: "p", used: 1, limitReached: false), W(id: "s", used: 2, limitReached: false)], account: "a", now: 30), .resume(blockedSince: 10))
        XCTAssertEqual(planner.observe(windows: [W(id: "p", used: 1, limitReached: false), W(id: "s", used: 2, limitReached: false)], account: "a", now: 40), .none)
    }

    func testAccountChangeAbandonsTheEpisode() {
        typealias W = AutoContinuePlanner.Window
        var planner = AutoContinuePlanner()
        XCTAssertEqual(planner.observe(windows: [W(id: "p", used: 100, limitReached: true)], account: "a", now: 10), .blocked(since: 10))
        XCTAssertEqual(planner.observe(windows: [W(id: "p", used: 5, limitReached: false)], account: "b", now: 20), .none, "another account's fresh quota is not a reset")
        XCTAssertFalse(planner.isBlocked)
        XCTAssertEqual(planner.observe(windows: [W(id: "p", used: 5, limitReached: false)], account: "a", now: 30), .none)
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
        XCTAssertEqual(CodexSessionLocator.interruptedSession(root: root, blockedSince: 10_150),
                       .session(CodexSessionReference(id: "main", cwd: "/w/main", modifiedAt: 10_000)))
        XCTAssertEqual(CodexSessionLocator.interruptedSession(root: root, blockedSince: 50_000), .none)
        // A session started after the limit was reached is never attributed to the interruption.
        try write("later.jsonl", id: "later", parent: nil, modified: 13_600)
        XCTAssertEqual(CodexSessionLocator.interruptedSession(root: root, blockedSince: 10_150),
                       .session(CodexSessionReference(id: "main", cwd: "/w/main", modifiedAt: 10_000)))
        // Two sessions active at the interruption are ambiguous rather than guessed.
        try write("other.jsonl", id: "other", parent: nil, modified: 10_120)
        guard case .ambiguous(let sessions) = CodexSessionLocator.interruptedSession(root: root, blockedSince: 10_150) else { return XCTFail("expected ambiguity") }
        XCTAssertEqual(sessions.map(\.id), ["other", "main"])
    }
}
