import AppKit
import Security
import ServiceManagement
import UsageCore

/// Stores provider API keys in the login keychain, never in preferences or files.
enum KeychainSecret {
    private static let service = "io.github.dwagwd.quotapilot"

    /// Keys saved before the QuotaPilot rename live under the old service name.
    private static let legacyService = "local.codex.usage-widget"

    static func read(_ account: String) -> String? {
        if let value = read(account, service: service) { return value }
        guard let legacy = read(account, service: legacyService) else { return nil }
        if write(account, value: legacy) { _ = delete(account, service: legacyService) }
        return legacy
    }

    @discardableResult
    private static func delete(_ account: String, service: String) -> Bool {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary) == errSecSuccess
    }

    private static func read(_ account: String, service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ account: String, value: String?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

enum AgentDetection {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeInstalled: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) }
    static var antigravityInstalled: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-cli").path) }
    static var cursorInstalled: Bool {
        ["/Applications/Cursor.app", home.appendingPathComponent("Applications/Cursor.app").path].contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func bridgeInstalled(_ provider: String) -> Bool {
        let settings = home.appendingPathComponent(provider == "claude" ? ".claude/settings.json" : ".gemini/antigravity-cli/settings.json")
        guard let data = try? Data(contentsOf: settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["statusLine"] as? [String: Any], let command = status["command"] as? String else { return false }
        return command.contains("QuotaPilot/bridges/") || command.contains("CodexUsageWidget/bridges/")
    }

    /// Runs the bundled setup script; it keeps the user's existing status line and backs up settings.
    static func installBridge(_ provider: String) -> (ok: Bool, output: String) {
        guard let script = Bundle.main.url(forResource: "setup-provider", withExtension: "py") else {
            return (false, "setup-provider.py is not bundled in this build.")
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, provider]
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// macOS login item for the app bundle itself (macOS 13+ `SMAppService`).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch { return false }
    }
}

extension AgentDetection {
    /// A DeepSeek key only from places that are explicitly DeepSeek configuration: the widget's keychain item,
    /// or Claude Code's `env` when its Anthropic-compatible base URL points at api.deepseek.com.
    static func deepSeekKey() -> String? {
        if let key = KeychainSecret.read("deepseek") { return key }
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json")) else { return nil }
        return DeepSeekBalance.key(fromClaudeSettings: data)
    }

    /// Status-line bridges that can be installed without overwriting a non-command status line.
    static func pendingBridges() -> [String] {
        [("claude", claudeInstalled), ("antigravity", antigravityInstalled)].compactMap { provider, installed in
            guard installed, !bridgeInstalled(provider) else { return nil }
            let path = home.appendingPathComponent(provider == "claude" ? ".claude/settings.json" : ".gemini/antigravity-cli/settings.json")
            if let data = try? Data(contentsOf: path),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = object["statusLine"] as? [String: Any], status["type"] as? String != "command" { return nil }
            return provider
        }
    }
}

extension KeychainSecret {
    /// Claude Code's own login item. macOS asks the user once before another app may read it.
    static func claudeCodeCredentials() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Claude Code-credentials",
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data { return data }
        return try? Data(contentsOf: AgentDetection.home.appendingPathComponent(".claude/.credentials.json"))
    }
}

/// Optional, user-chosen links between agents. Model-to-model review goes through the other agent's
/// non-interactive CLI (`claude -p`, `codex exec`) wrapped in a skill; the MCP link only exposes Claude Code's
/// tools to Codex and is kept separate. Every link can be removed from the same menu.
enum AgentCollaboration {
    enum Link: String, CaseIterable { case claudeToCodex, codexToClaude, claudeOrchestratesCodex, codexOrchestratesClaude, codexUsesClaudeTools }
    static let mcpName = "claude-tools"
    static let marker = "<!-- installed by QuotaPilot -->"
    /// Set by a delegated run; a skill that sees it does not delegate again, so two agents cannot loop.
    static let depthVariable = "AGENT_DELEGATION_DEPTH"

    static var claudeSkill: URL { AgentDetection.home.appendingPathComponent(".claude/skills/codex-review", isDirectory: true) }
    static var codexSkill: URL { AgentDetection.home.appendingPathComponent(".codex/skills/claude-review", isDirectory: true) }
    static var claudeOrchestratorSkill: URL { AgentDetection.home.appendingPathComponent(".claude/skills/orchestrate-codex", isDirectory: true) }
    static var codexOrchestratorSkill: URL { AgentDetection.home.appendingPathComponent(".codex/skills/orchestrate-claude", isDirectory: true) }
    static var legacyClaudeSkill: URL { AgentDetection.home.appendingPathComponent(".claude/skills/codex-delegate", isDirectory: true) }

    static var claudeExecutable: String? {
        let home = AgentDetection.home.path
        return [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> (ok: Bool, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private static func ownsSkill(_ directory: URL) -> Bool {
        (try? String(contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8))?.contains(marker) ?? false
    }

    static func isEnabled(_ link: Link, codex: String?) -> Bool {
        switch link {
        case .claudeToCodex: return ownsSkill(claudeSkill)
        case .codexToClaude: return ownsSkill(codexSkill)
        case .claudeOrchestratesCodex: return ownsSkill(claudeOrchestratorSkill)
        case .codexOrchestratesClaude: return ownsSkill(codexOrchestratorSkill)
        case .codexUsesClaudeTools: return codex.map { run($0, ["mcp", "get", mcpName]).ok } ?? false
        }
    }

    static func set(_ link: Link, enabled: Bool, codex: String) -> (ok: Bool, output: String) {
        if ownsSkill(legacyClaudeSkill) { try? FileManager.default.removeItem(at: legacyClaudeSkill) }
        switch link {
        case .codexUsesClaudeTools:
            if !enabled { return run(codex, ["mcp", "remove", mcpName]) }
            guard let claude = claudeExecutable else { return (false, "Claude Code CLI not found") }
            return run(codex, ["mcp", "add", mcpName, "--", claude, "mcp", "serve"])
        case .claudeToCodex:
            return writeSkill(at: claudeSkill, enabled: enabled, text: claudeSkillText(codex: codex))
        case .codexToClaude:
            guard let claude = claudeExecutable else { return (false, "Claude Code CLI not found") }
            return writeSkill(at: codexSkill, enabled: enabled, text: codexSkillText(claude: claude))
        case .claudeOrchestratesCodex:
            let worker = "\(depthVariable)=1 \"\(codex)\" exec --sandbox workspace-write --skip-git-repo-check -C \"$REPO\" \"$(cat \"$SPEC\")\""
            let readOnly = "\(depthVariable)=1 \"\(codex)\" exec --sandbox read-only --skip-git-repo-check -C \"$REPO\" \"$(cat \"$SPEC\")\""
            return writeSkill(at: claudeOrchestratorSkill, enabled: enabled,
                              text: orchestratorText(name: "orchestrate-codex", me: "Claude Code", meID: "claude", worker: "Codex", workerID: "codex", command: worker, readOnlyCommand: readOnly))
        case .codexOrchestratesClaude:
            guard let claude = claudeExecutable else { return (false, "Claude Code CLI not found") }
            let worker = "cd \"$REPO\" && \(depthVariable)=1 \"\(claude)\" -p --permission-mode acceptEdits \"$(cat \"$SPEC\")\""
            let readOnly = "cd \"$REPO\" && \(depthVariable)=1 \"\(claude)\" -p --permission-mode plan \"$(cat \"$SPEC\")\""
            return writeSkill(at: codexOrchestratorSkill, enabled: enabled,
                              text: orchestratorText(name: "orchestrate-claude", me: "Codex", meID: "codex", worker: "Claude", workerID: "claude", command: worker, readOnlyCommand: readOnly))
        }
    }

    private static func writeSkill(at directory: URL, enabled: Bool, text: String) -> (ok: Bool, output: String) {
        if !enabled {
            guard ownsSkill(directory) else { return (true, "") }
            do { try FileManager.default.removeItem(at: directory); return (true, "") } catch { return (false, error.localizedDescription) }
        }
        if FileManager.default.fileExists(atPath: directory.path) && !ownsSkill(directory) {
            return (false, directory.path + " already exists and was not created by this app")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: directory.appendingPathComponent("SKILL.md"), options: .atomic)
            return (true, directory.path)
        } catch { return (false, error.localizedDescription) }
    }

    private static var routerNote: String {
        let status = support.appendingPathComponent("status.json").path
        return """
        Before delegating, read `\(status)` → `router.byTask.review.agent` (the user's review rule with quota fallback). Delegate when it names the other agent or the user explicitly asked for it. If it is null, tell the user both agents are low on quota.
        If the environment variable `\(depthVariable)` is already set, you are running as a delegate: do the work yourself and never delegate again.
        """
    }

    static func claudeSkillText(codex: String) -> String {
        """
        ---
        name: codex-review
        description: Get an independent code review or second opinion from OpenAI Codex (codex exec, read-only). Use when the user asks for Codex, an independent review, or when the quota router prefers Codex.
        ---
        \(marker)

        # Independent review by Codex

        \(routerNote)

        1. Confirm the working directory is a Git repository and there is a diff to review (`git diff`, or `git diff <base>...HEAD` for a branch).
        2. Run, from the repository root:

           git diff | \(depthVariable)=1 "\(codex)" exec --sandbox read-only --skip-git-repo-check "Independently review the diff on stdin. List bugs, risks and improvements with severity and file:line. Do not modify files."

        3. Summarize Codex's findings for the user, marking which you agree with after checking the code yourself.
        4. Do not apply fixes automatically.
        """
    }

    /// The orchestrator plans, delegates implementation to the worker CLI, then verifies and accepts or sends
    /// focused fixes back. The worker only implements; it never re-plans, commits or delegates.
    static func orchestratorText(name: String, me: String, meID: String, worker: String, workerID: String,
                                 command: String, readOnlyCommand: String) -> String {
        let status = support.appendingPathComponent("status.json").path
        return """
        ---
        name: \(name)
        description: Orchestrator mode with task routing between \(me) and \(worker). The user's rules decide who handles web/research, review, planning and implementation; \(me) coordinates and verifies. Use when the user asks to orchestrate, to route work by task, or to have \(worker) do part of the work.
        ---
        \(marker)

        # \(me) orchestrates, work is routed by task

        If the environment variable `\(depthVariable)` is set, you are already a delegate: do the task yourself and do not use this skill.

        ## 0. Route each part of the work
        Classify each part of the request as `web` (needs internet: browsing, online docs, package or API research), `review`, `plan` or `implement` (everything else).
        Read `\(status)` → `router.byTask.<kind>.agent`. That value already applies the user's rules and falls back when an agent's quota is low.
        - `\(meID)`: do that part yourself.
        - `\(workerID)`: hand that part to \(worker) (steps below).
        - `null`: both agents are low on quota; tell the user before continuing.

        ## 1. Plan
        If `router.byTask.plan.agent` is you, read the code and plan yourself. If it is `\(workerID)`, write the request to a spec file and ask \(worker) for a plan (read-only):

            \(readOnlyCommand)

        Either way, split the work into tasks you can verify one by one. For each task write a spec file outside the repository (`SPEC=$(mktemp -t spec).md`): goal, files to change, constraints and conventions, acceptance criteria, and exact verification commands. Tell the delegate: do only this task, do not commit, do not touch unrelated files, report what changed and any doubts.

        ## 2. Delegate
        From the repository root (`REPO=$(git rev-parse --show-toplevel)`):
        - Implementation or web work for \(worker):

              \(command)

        - Review or research that must not edit files:

              \(readOnlyCommand)

        ## 3. Verify (always you)
        Inspect `git diff` against the spec and run the verification commands yourself; never accept a delegate's claim unchecked. If something fails, write a short follow-up spec with the exact failures and delegate again. Stop after three rounds and report what is still failing.

        ## 4. Report
        Say who did which part (and why: rule or quota fallback), what changed, what you verified with command output, and what is left. Commit only if the user's normal workflow asks for it.
        """
    }

    static func codexSkillText(claude: String) -> String {
        """
        ---
        name: claude-review
        description: Get an independent code review or second opinion from Claude (claude -p in plan mode, no edits). Use when the user asks for Claude, an independent review, or when the quota router prefers Claude.
        ---
        \(marker)

        # Independent review by Claude

        \(routerNote)

        1. Confirm the working directory is a Git repository and there is a diff to review.
        2. Run, from the repository root:

           git diff | \(depthVariable)=1 "\(claude)" -p --permission-mode plan "Independently review the diff on stdin. List bugs, risks and improvements with severity and file:line. Do not modify files."

        3. Summarize Claude's findings, noting which you verified in the code.
        4. Do not apply fixes automatically.
        """
    }
}
