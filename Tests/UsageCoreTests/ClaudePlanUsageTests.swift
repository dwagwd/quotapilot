import XCTest
@testable import UsageCore

final class ClaudePlanUsageTests: XCTestCase {
    func testConvertsSessionAndWeeklyWindows() throws {
        let body = #"{"five_hour":{"utilization":24.0,"resets_at":"2026-10-15T17:10:00.017191+00:00"},"seven_day":{"utilization":95.0,"resets_at":"2026-10-15T19:00:00+00:00"},"seven_day_opus":null,"iguana_necktie":{"utilization":0}}"#
        let snapshot = try XCTUnwrap(ClaudePlanUsage.snapshot(from: Data(body.utf8), plan: "max", now: 1_000))
        XCTAssertTrue(snapshot.isValid(now: 1_000, expectedProvider: "claude"))
        let windows = snapshot.limits.windows()
        XCTAssertEqual(Set(windows.map(\.id)), ["claude:five_hour:primary", "claude:seven_day:primary"])
        let session = try XCTUnwrap(windows.first { $0.id == "claude:five_hour:primary" })
        XCTAssertEqual(session.window.usedPercent, 24)
        XCTAssertEqual(session.window.windowDurationMins, 300)
        XCTAssertEqual(session.planType, "max")
        XCTAssertEqual(session.window.resetsAt ?? 0, 1_792_084_200.017, accuracy: 0.01)
        XCTAssertNil(ClaudePlanUsage.snapshot(from: Data(#"{"error":"unauthorized"}"#.utf8), plan: nil, now: 0))
    }

    func testReadsAccessTokenAndPlanFromClaudeCodeCredentials() {
        let creds = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1792072961569,"subscriptionType":"max"}}"#
        let parsed = ClaudePlanUsage.credentials(from: Data(creds.utf8))
        XCTAssertEqual(parsed?.token, "tok")
        XCTAssertEqual(parsed?.plan, "max")
        XCTAssertEqual(parsed?.expiresAt ?? 0, 1_792_072_961.569, accuracy: 0.001)
        XCTAssertNil(ClaudePlanUsage.credentials(from: Data("{}".utf8)))
    }
}
