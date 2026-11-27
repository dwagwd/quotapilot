import XCTest
@testable import UsageCore

final class LocalizationCompletenessTests: XCTestCase {
    /// Every interface string must have all ten languages.
    private var codes: [String] { WidgetLanguage.allCases.filter { $0 != .system }.map(\.rawValue) }

    func testEveryStringHasEveryLanguage() {
        var gaps: [String] = []
        for (key, values) in L10n.table.sorted(by: { $0.key < $1.key }) {
            let missing = codes.filter { values[$0]?.isEmpty != false }
            if !missing.isEmpty { gaps.append(key + ": " + missing.joined(separator: ",")) }
        }
        XCTAssertTrue(gaps.isEmpty, "Missing translations:\n" + gaps.joined(separator: "\n"))
    }

    /// The Settings window, statistics window, local models window and energy lines must be fully translated.
    func testWindowStringsAreTranslated() {
        let keys = ["openAtLogin", "openAtLoginHelp", "consentClaudePlan", "autoConnect", "agentCollaboration", "connectAgents", "usageStats", "localModels",
                    "statsTokens", "statsQuota", "outputSpeedHelp", "communityCompare", "field.total", "localEnable", "energyTitle", "energyCost"]
        for key in keys {
            for code in codes { XCTAssertFalse(L10n.table[key]?[code, default: ""].isEmpty ?? true, "\(key) \(code)") }
        }
    }

    /// Format specifiers must survive translation in the same order, or String(format:) misreads the arguments.
    func testTranslationsKeepFormatSpecifiers() {
        let pattern = try! NSRegularExpression(pattern: "%(\\d+\\$)?[-+0#]*\\d*(\\.\\d+)?(ll|l)?[@dsfiuxXcC]")
        func specifiers(_ s: String) -> [String] {
            let text = s.replacingOccurrences(of: "%%", with: "")
            return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range).replacingOccurrences(of: "i", with: "d") }   // %i and %d are the same
        }
        for (key, values) in L10n.table {
            guard let english = values["en"] else { continue }
            for (code, text) in values where code != "en" { XCTAssertEqual(specifiers(text), specifiers(english), "\(key) \(code)") }
        }
    }
}
