import XCTest
@testable import UsageCore

final class LocalizationCompletenessTests: XCTestCase {
    /// Strings that still exist only in English and Chinese (menus, dialogs, task ledger, diagnostics). They show English in the
    /// other eight languages. New strings must have all ten languages; translate one of these and delete it from the list.
    private static let knownGaps: Set<String> = [
        "accountChanged", "accountIdentityMismatch", "agentQuotaBridge", "agentTokensAuto", "autoContinueAmbiguous",
        "autoContinueSkipped", "autoContinueStarted", "autoShare", "autoShareExplain", "autoShareOn", "autoUpdateChecks",
        "bridgeInstalledRestart", "collaborationIntro", "collaborationRestart", "connectAgentsTitle", "connectAntigravity",
        "connectClaude", "connected", "consentAutoConnect", "consentAutoConnectNote", "consentBody", "consentContinue", "consentMenu",
        "consentShareNote", "consentTitle", "consumptionRate", "cursorNote", "dataAge", "deepSeekBalance", "deepSeekError", "deepSeekKey",
        "deepSeekKeyPrompt", "deepSeekNote", "downloadingUpdate", "errorCode", "eventAccountSwitch", "eventAccountTokenTotal",
        "eventAccountTokens", "eventAppendFailed", "eventCheckpoint", "eventDataGap", "eventLogMissing", "eventSincePriorCheckpoint",
        "eventSourceCorrection", "eventSourceFailure", "eventSourceRecovered", "eventStateMissing", "eventStateUnreadable",
        "eventStateWriteFailed", "eventWindowReset", "eventWindowRestored", "eventWindowUnavailable", "exportTaskLedger",
        "exportUsageEvents", "failureCount", "finishTask", "finishTaskInfo", "finishTaskTitle", "forgetConfirm", "forgetDone",
        "forgetDoneBody", "forgetExplain", "forgetFailed", "forgetShared", "installNow", "installUpdate", "invalidTokenCount",
        "invalidTokenResponse", "lastAttempt", "lastSuccess", "link.claudeOrchestratesCodex", "link.claudeToCodex",
        "link.codexOrchestratesClaude", "link.codexToClaude", "link.codexUsesClaudeTools", "linkGitHub", "linkIssue", "linkSponsor",
        "linkWebsite", "nextAttempt", "notConnected", "notInstalled", "observationUnavailable", "openCommunity", "outcomeAbandoned",
        "outcomeAccepted", "outcomeFailed", "outcomeInterrupted", "outcomeNeedsWork", "outcomeNotRun", "periodAccountChange",
        "periodAccountTokenChange", "restartToUpdate", "retryUpdate", "router.auto", "router.preferClaude", "router.preferCodex",
        "routerMode", "routerNone", "shareKind.limitEvents", "shareKind.promptCache", "shareKind.quota", "shareKind.speed", "shareKinds",
        "snapshotInvalid", "snapshotMissing", "snapshotTooLarge", "snapshotUnreadable", "sourceAntigravity", "sourceClaude",
        "sourceCodexQuota", "sourceCodexTokens", "sourceCursor", "sourceDiagnosticIntro", "sourceDiagnostics", "sourceDisabled",
        "sourceError", "sourceFresh", "sourcePaused", "sourceUsageEventLedger", "sourceValueAge", "staleAfter", "startTask",
        "startTaskInfo", "startTaskTitle", "suggestedAgent", "task.implement", "task.plan", "task.review", "task.web", "taskActiveLabel",
        "taskDuration", "taskExportFailed", "taskExportPrompt", "taskExported", "taskHistory", "taskHistoryEmpty", "taskIssueField",
        "taskModelField", "taskNoActive", "taskNotesField", "taskOutcomeField", "taskOutcomeLabel", "taskProjectField",
        "taskReasoningField", "taskRetriesField", "taskRetriesLabel", "taskRules", "taskSaveFailed", "taskSessionTokens",
        "taskSessionUsageUnavailable", "taskTitleField", "taskTitleRequired", "tokenReadFailed", "tokenTimeout", "tokenUnavailable",
        "upToDate", "updateAvailable", "updateBrew", "updateConfirm", "updateFailed", "updateHowTo", "updatedBody", "updatedTo",
        "usageEventExportFailed", "usageEventExportPrompt", "usageEventExported", "usageEventHistory", "usageEventHistoryEmpty",
        "windowReachedDuringTask", "windowResetDuringTask"
    ]

    private var codes: [String] { WidgetLanguage.allCases.filter { $0 != .system }.map(\.rawValue) }

    func testNewStringsHaveEveryLanguage() {
        var gaps: [String] = []
        for (key, values) in L10n.table.sorted(by: { $0.key < $1.key }) where !Self.knownGaps.contains(key) {
            let missing = codes.filter { values[$0]?.isEmpty != false }
            if !missing.isEmpty { gaps.append(key + ": " + missing.joined(separator: ",")) }
        }
        XCTAssertTrue(gaps.isEmpty, "Missing translations:\n" + gaps.joined(separator: "\n"))
    }

    func testKnownGapListShrinksWhenStringsAreTranslated() {
        for key in Self.knownGaps.sorted() {
            guard let values = L10n.table[key] else { XCTFail("\(key) no longer exists: remove it from knownGaps"); continue }
            XCTAssertFalse(codes.allSatisfy { values[$0]?.isEmpty == false }, "\(key) is complete now: remove it from knownGaps")
        }
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
