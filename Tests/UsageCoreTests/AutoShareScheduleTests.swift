import XCTest
@testable import UsageCore

final class AutoShareScheduleTests: XCTestCase {
    func testFullCollectorRetriesAboutThreeHoursLater() {
        let now = 1_000_000.0
        XCTAssertTrue(AutoShareSchedule.isDue(lastAttempt: 0, now: now))
        XCTAssertFalse(AutoShareSchedule.isDue(lastAttempt: now, now: now + 3600))
        let stamp = AutoShareSchedule.retryStamp(after: now)
        XCTAssertFalse(AutoShareSchedule.isDue(lastAttempt: stamp, now: now + 3 * 3600 - 1))
        XCTAssertTrue(AutoShareSchedule.isDue(lastAttempt: stamp, now: now + 3 * 3600))
    }

    func testFailureFromA429JSONBodyIsCollectorFull() {
        let body = Data(#"{"error":"collector is full for today","full":true}"#.utf8)
        let failure = ShareFailure(status: 429, body: body)
        XCTAssertEqual(failure.status, 429)
        XCTAssertEqual(failure.message, "collector is full for today")
        XCTAssertTrue(failure.collectorFull)
        XCTAssertTrue(AutoShareSchedule.isCollectorFull(failure))
        XCTAssertEqual(failure.localizedDescription, "collector is full for today")
        XCTAssertEqual((failure as NSError).code, 429)
    }

    func testFullFallbackUsesStatusAndMessage() {
        let body = Data(#"{"error":"collector is full for today"}"#.utf8)
        let failure = ShareFailure(status: 429, body: body)
        XCTAssertFalse(failure.collectorFull)
        XCTAssertTrue(AutoShareSchedule.isCollectorFull(failure))
    }

    func testOtherFailuresAreNotCollectorFull() {
        XCTAssertFalse(AutoShareSchedule.isCollectorFull(ShareFailure(status: 500, body: nil)))
        XCTAssertEqual(ShareFailure(status: 500, body: nil).message, "HTTP 500")
        let rate = ShareFailure(status: 429, body: Data(#"{"error":"too many requests"}"#.utf8))
        XCTAssertFalse(AutoShareSchedule.isCollectorFull(rate))
        let text = ShareFailure(status: 0, body: nil, transportError: "offline")
        XCTAssertEqual(text.message, "offline")
        XCTAssertFalse(AutoShareSchedule.isCollectorFull(text))
    }
}
