import XCTest
@testable import UsageCore

final class CommunityComparisonTests: XCTestCase {
    let published = Data(#"""
    {"generated":"2026-11-14T00:00:00Z","minSamples":3,"totals":{"reporters":7},
     "speed":[{"model":"claude-opus-5-5","n":5,"median":100,"p25":80,"p75":120},{"model":"gpt-6-1-sol","n":4,"median":30},{"model":"bad","median":-1}],
     "quota":[{"provider":"claude","plan":"Max 5x","window":"weekly","n":3,"medianTokens":200000000}]}
    """#.utf8)

    func testParsesOnlyWellFormedRows() throws {
        let p = try XCTUnwrap(CommunityComparison.parse(published))
        XCTAssertEqual(p.people, 7)
        XCTAssertEqual(p.minPeople, 3)
        XCTAssertEqual(p.speed.map(\.model), ["claude-opus-5-5", "gpt-6-1-sol"])
        XCTAssertEqual(p.quota.first?.plan, "Max 5x")
        XCTAssertNil(CommunityComparison.parse(Data("not json".utf8)))
    }

    func testComparesSpeedAcrossEffortsAndQuotaPerWindow() throws {
        let p = try XCTUnwrap(CommunityComparison.parse(published))
        let mine: [[String: Any]] = [
            ["type": "speed", "model": "claude-opus-5-5", "effort": "high", "outputTokens": 1000.0, "seconds": 10.0],
            ["type": "speed", "model": "claude-opus-5-5", "effort": "low", "outputTokens": 2000.0, "seconds": 10.0],
            ["type": "speed", "model": "unpublished-model", "outputTokens": 500.0, "seconds": 5.0],
            ["type": "quota", "provider": "claude", "plan": "Max 5x", "window": "weekly", "percentUsed": 25.0, "tokensUsed": 60_000_000.0],
            ["type": "quota", "provider": "claude", "plan": "Max 5x", "window": "5h", "percentUsed": 5.0, "tokensUsed": 1_000_000.0]
        ]
        let lines = CommunityComparison.compare(mine: mine, with: p)
        XCTAssertEqual(lines.count, 2, "only published subjects; the unpublished 5-hour window is left out")
        XCTAssertEqual(lines[0].kind, .speed)
        XCTAssertEqual(lines[0].mine, 150, accuracy: 0.001, "3000 tokens over 20 s, all efforts together")
        XCTAssertEqual(lines[0].ratio, 1.5, accuracy: 0.001)
        XCTAssertEqual(lines[1].kind, .quota)
        XCTAssertEqual(lines[1].mine, 240_000_000, accuracy: 1)
        XCTAssertTrue(CommunityComparison.describe(lines[0]).contains("50% faster than the median 100 tok/s of 5 people"))
        XCTAssertTrue(CommunityComparison.describe(lines[1]).contains("20% more than"))
    }

    func testNothingToCompareWithoutPublishedRows() throws {
        let empty = try XCTUnwrap(CommunityComparison.parse(Data(#"{"speed":[],"quota":[],"totals":{"reporters":1}}"#.utf8)))
        XCTAssertTrue(CommunityComparison.compare(mine: [["type": "speed", "model": "claude-opus-5-5", "outputTokens": 1.0, "seconds": 1.0]], with: empty).isEmpty)
    }
}
