import XCTest
@testable import UsageCore

final class QuotaSortingTests: XCTestCase {
    private func item(_ id: String, _ name: String, used: Double, reset: Double) -> WindowItem {
        WindowItem(id: id, name: name, window: QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset))
    }
    private var groups: [[WindowItem]] {
        [[item("codex:primary", "Codex", used: 7, reset: 500_000)],
         [item("claude:five_hour:primary", "Claude", used: 37, reset: 9_000), item("claude:seven_day:primary", "Claude", used: 96, reset: 16_000)],
         [item("cursor:spend:primary", "Cursor", used: 50, reset: 2_000)]]
    }
    private func order(_ sort: QuotaSort, pinned: [String] = []) -> [String] {
        sortQuotaGroups(groups, sort: sort, pinned: pinned, now: 0).map { $0.first!.name }
    }

    func testSortModes() {
        XCTAssertEqual(order(.detected), ["Codex", "Claude", "Cursor"])
        XCTAssertEqual(order(.mostUsed), ["Claude", "Cursor", "Codex"])
        XCTAssertEqual(order(.resetSoonest), ["Cursor", "Claude", "Codex"])
        XCTAssertEqual(order(.name), ["Claude", "Codex", "Cursor"])
    }

    func testPinnedProvidersComeFirst() {
        XCTAssertEqual(order(.mostUsed, pinned: ["codex"]), ["Codex", "Claude", "Cursor"])
        XCTAssertEqual(order(.detected, pinned: ["cursor", "claude"]), ["Cursor", "Claude", "Codex"])
    }
}
