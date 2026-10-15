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
