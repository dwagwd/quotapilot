import XCTest
@testable import UsageCore

final class DeepSeekBalanceTests: XCTestCase {
    func testParsesStringAmountsPerCurrency() throws {
        let body = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},{"currency":"USD","total_balance":"0.5"}]}"#
        let parsed = try XCTUnwrap(DeepSeekBalance.parse(Data(body.utf8)))
        XCTAssertTrue(parsed.available)
        XCTAssertEqual(parsed.balances, [DeepSeekBalance(currency: "CNY", total: 110, granted: 10, toppedUp: 100),
                                         DeepSeekBalance(currency: "USD", total: 0.5, granted: nil, toppedUp: nil)])
    }

    func testRejectsErrorsAndBadAmounts() {
        XCTAssertNil(DeepSeekBalance.parse(Data(#"{"error":{"message":"Authentication Fails"}}"#.utf8)))
        let parsed = DeepSeekBalance.parse(Data(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"n/a"}]}"#.utf8))
        XCTAssertEqual(parsed?.available, false)
        XCTAssertEqual(parsed?.balances, [])
    }

    func testKeyIsTakenFromClaudeSettingsOnlyForDeepSeekEndpoints() {
        let deepseek = #"{"env":{"ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic","ANTHROPIC_AUTH_TOKEN":"sk-test"}}"#
        XCTAssertEqual(DeepSeekBalance.key(fromClaudeSettings: Data(deepseek.utf8)), "sk-test")
        let other = #"{"env":{"ANTHROPIC_BASE_URL":"https://deepseek.com.evil.example","ANTHROPIC_AUTH_TOKEN":"sk-test"}}"#
        XCTAssertNil(DeepSeekBalance.key(fromClaudeSettings: Data(other.utf8)))
        XCTAssertNil(DeepSeekBalance.key(fromClaudeSettings: Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"sk"}}"#.utf8)))
    }
}
