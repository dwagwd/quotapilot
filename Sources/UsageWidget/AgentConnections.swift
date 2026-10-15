import AppKit
import Security
import ServiceManagement
import UsageCore

/// Stores provider API keys in the login keychain, never in preferences or files.
enum KeychainSecret {
    private static let service = "local.codex.usage-widget"

    static func read(_ account: String) -> String? {
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
        return command.contains("CodexUsageWidget/bridges/")
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

/// Optional, user-chosen links between agents. Each step uses the agents' own configuration commands
/// and can be removed again from the same menu.
enum AgentCollaboration {
    static let codexServerName = "claude-code"
    static var skillDirectory: URL { AgentDetection.home.appendingPathComponent(".claude/skills/codex-delegate", isDirectory: true) }
    static let skillMarker = "<!-- installed by Codex Usage Widget -->"

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

    static func codexCanCallClaude(codex: String?) -> Bool {
        guard let codex else { return false }
        return run(codex, ["mcp", "get", codexServerName]).ok
    }

    static var claudeCanCallCodex: Bool {
        (try? String(contentsOf: skillDirectory.appendingPathComponent("SKILL.md"), encoding: .utf8))?.contains(skillMarker) ?? false
    }

    /// Codex gets Claude Code as an MCP server (`claude mcp serve`).
    static func setCodexCallsClaude(_ enabled: Bool, codex: String) -> (ok: Bool, output: String) {
        if !enabled { return run(codex, ["mcp", "remove", codexServerName]) }
        guard let claude = claudeExecutable else { return (false, "Claude Code CLI not found") }
        return run(codex, ["mcp", "add", codexServerName, "--", claude, "mcp", "serve"])
    }

    /// Claude Code gets a skill that hands a task to `codex exec` and checks Codex quota first.
    static func setClaudeCallsCodex(_ enabled: Bool, codex: String) -> (ok: Bool, output: String) {
        let skill = skillDirectory.appendingPathComponent("SKILL.md")
        if !enabled {
            guard claudeCanCallCodex else { return (true, "") }
            do { try FileManager.default.removeItem(at: skillDirectory); return (true, "") } catch { return (false, error.localizedDescription) }
        }
        let status = support.appendingPathComponent("status.json").path
        let text = """
        ---
        name: codex-delegate
        description: Hand a well-scoped coding task, investigation or second-opinion review to OpenAI Codex via its CLI. Use when the user asks for Codex, a second opinion, or when Claude quota is low and Codex has room.
        ---
        \(skillMarker)

        # Delegate to Codex

        1. Check quota first: read `\(status)`. If `suggestedAgent` is `codex`, or the user asked for Codex, continue. If the Codex window's `usedPercent` is 95 or higher, tell the user Codex is nearly out of quota instead of delegating.
        2. Write a self-contained prompt: goal, relevant files, constraints and how to verify. Codex does not see this conversation.
        3. Run it in the project folder:
           - Review or question (no edits): `"\(codex)" exec --sandbox read-only -C "<project dir>" "<prompt>"`
           - Implementation: `"\(codex)" exec --sandbox workspace-write -C "<project dir>" "<prompt>"`
        4. Read Codex's final message, inspect any changed files with `git diff`, verify the result yourself, and report what Codex did.
        """
        do {
            try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: skill, options: .atomic)
            return (true, skill.path)
        } catch { return (false, error.localizedDescription) }
    }
}
