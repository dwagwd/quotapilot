import XCTest
@testable import UsageCore

final class PlanCatalogTests: XCTestCase {
    func testChatGPTAndClaudePlanNames() {
        XCTAssertEqual(PlanCatalog.displayName(provider: "codex", raw: "plus"), "Plus")
        XCTAssertEqual(PlanCatalog.displayName(provider: "codex", raw: "team"), "Business")
        XCTAssertEqual(PlanCatalog.displayName(provider: "claude", raw: "team"), "Team")
        XCTAssertEqual(PlanCatalog.displayName(provider: "claude", raw: "max_5x"), "Max 5x")
        XCTAssertEqual(PlanCatalog.displayName(provider: "claude", raw: "max_20x"), "Max 20x")
        XCTAssertEqual(PlanCatalog.displayName(provider: "codex", raw: "pro_20x"), "Pro 20x")
        XCTAssertNil(PlanCatalog.displayName(provider: "codex", raw: ""))
        XCTAssertEqual(PlanCatalog.displayName(provider: "codex", raw: "some_new_plan"), "Some New Plan")
    }

    func testGooglePlansAndGeminiAuthDetection() {
        XCTAssertEqual(PlanCatalog.displayName(provider: "gemini", raw: "standard_tier"), "Gemini Code Assist Standard")
        XCTAssertEqual(PlanCatalog.displayName(provider: "gemini", raw: "google-ai-ultra"), "Google AI Ultra")
        let nested = #"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#
        XCTAssertEqual(PlanCatalog.geminiAuthType(settings: Data(nested.utf8)), "oauth_personal")
        XCTAssertEqual(PlanCatalog.geminiAuthType(settings: Data(#"{"selectedAuthType":"gemini-api-key"}"#.utf8)), "gemini_api_key")
        XCTAssertNil(PlanCatalog.geminiAuthType(settings: Data("{}".utf8)))
        XCTAssertTrue(PlanCatalog.plans.contains { $0.provider == "gemini" && $0.name == "Google AI Pro" })
    }
}
