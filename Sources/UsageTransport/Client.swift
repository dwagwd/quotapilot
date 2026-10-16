import Foundation
import UsageCore

public struct ClientDiagnostics: Codable, Equatable {
    public let lastAttemptAt: Double?
    public let lastQuotaSuccessAt: Double?
    public let lastTokenAttemptAt: Double?
    public let lastTokenSuccessAt: Double?
    public let lastTokenAttemptAccountKey: String?
    public let lastTokenSuccessAccountKey: String?
    public let lastFailureCode: String?
    public let lastTokenErrorCode: String?
    public let consecutiveFailures: Int
    public let consecutiveTokenFailures: Int
    public let nextAttemptAt: Double?
    public let connected: Bool
    public let requestInFlight: Bool
    public let suspended: Bool
}

// All mutable state is confined to the main queue. No model turns are created.
private func forceKill(_ process: Process) {
    #if os(Windows)
    process.terminate()
    #else
    kill(process.processIdentifier, SIGKILL)
    #endif
}

public final class UsageClient {
    private let overrideExecutable: String?
    private let requestTimeout: Double
    public var pollInterval: Double
    private let retryBase: Double
    public init(executable: String? = nil, requestTimeout: Double = 20, pollInterval: Double = 60, retryBase: Double = 15) {
        overrideExecutable = executable; self.requestTimeout = requestTimeout; self.pollInterval = pollInterval; self.retryBase = retryBase
    }
    public var onResult: ((LimitsResponse, String) -> Void)?
    public var onTokens: ((Double?, String) -> Void)?
    public var onDiagnostics: ((ClientDiagnostics) -> Void)?
    private var pendingTokenAccount: String?
    public var onFailure: ((String) -> Void)?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var ready = false
    private var inFlight = false
    private var accountIdentity: String?
    private var timeout: Timer?
    private var retryTimer: Timer?
    private var failures = 0
    private var tokenFailures = 0
    private var suspended = false
    private var stopping = false
    public private(set) var executable: String?
    private var lastAttemptAt: Double?
    private var lastQuotaSuccessAt: Double?
    private var lastTokenAttemptAt: Double?
    private var lastTokenSuccessAt: Double?
    private var lastTokenAttemptAccountKey: String?
    private var lastTokenSuccessAccountKey: String?
    private var lastFailureCode: String?
    private var lastTokenErrorCode: String?
    private var nextAttemptAt: Double?

    public var diagnostics: ClientDiagnostics {
        ClientDiagnostics(lastAttemptAt: lastAttemptAt, lastQuotaSuccessAt: lastQuotaSuccessAt,
                          lastTokenAttemptAt: lastTokenAttemptAt, lastTokenSuccessAt: lastTokenSuccessAt,
                          lastTokenAttemptAccountKey: lastTokenAttemptAccountKey,
                          lastTokenSuccessAccountKey: lastTokenSuccessAccountKey,
                          lastFailureCode: lastFailureCode, lastTokenErrorCode: lastTokenErrorCode,
                          consecutiveFailures: failures, consecutiveTokenFailures: tokenFailures,
                          nextAttemptAt: nextAttemptAt,
                          connected: process?.isRunning == true && ready, requestInFlight: inFlight,
                          suspended: suspended)
    }

    public func refresh() {
        guard !suspended, !stopping, !inFlight else { return }
        retryTimer?.invalidate(); retryTimer = nil
        nextAttemptAt = nil; lastAttemptAt = Date().timeIntervalSince1970; publishDiagnostics()
        if process == nil { start(); return }
        guard ready else { return }
        inFlight = true; publishDiagnostics()
        armTimeout()
        accountReadDone = false; heldLimits = nil
        // Ask for limits first: current Codex app servers do not answer account/read until another
        // request has been handled, and limits already carry the account ID.
        send(["id": 3, "method": "account/rateLimits/read", "params": [:]])
        send(["id": 2, "method": "account/read", "params": [:]])
    }
    public func suspend() { suspended = true; disconnect(); retryTimer?.invalidate(); nextAttemptAt = nil; publishDiagnostics() }
    public func resume() { suspended = false; publishDiagnostics(); refresh() }
    public func stop() {
        stopping = true; retryTimer?.invalidate()
        let child = process
        disconnect()
        // Complete shutdown before the application's run loop exits.
        if let child {
            let deadline = Date().addingTimeInterval(2)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { forceKill(child); child.waitUntilExit() }
        }
    }

    /// Known Codex CLI locations, most specific first. Newer ChatGPT desktop builds ship the CLI under
    /// `Resources/codex-cli/` instead of `Resources/codex`.
    public static func executableCandidates(environment env: [String: String], home: String) -> [String] {
        let bundles = ["/Applications", home + "/Applications"].flatMap { root in
            ["Codex.app", "ChatGPT.app"].flatMap { app in
                ["\(root)/\(app)/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                 "\(root)/\(app)/Contents/Resources/codex-cli/bin/codex",
                 "\(root)/\(app)/Contents/Resources/codex"]
            }
        }
        #if os(Windows)
        let pathEntries = (env["PATH"] ?? env["Path"] ?? "").split(separator: ";").map { String($0) + "\\codex.exe" }
        let extra = [env["APPDATA"].map { $0 + "\\npm\\codex.exe" }, env["LOCALAPPDATA"].map { $0 + "\\Programs\\codex\\codex.exe" }].compactMap { $0 }
        return [env["QUOTAPILOT_CODEX_PATH"], env["CODEX_USAGE_CODEX_PATH"]].compactMap { $0 } + pathEntries + extra
        #else
        return [env["QUOTAPILOT_CODEX_PATH"], env["CODEX_USAGE_CODEX_PATH"]].compactMap { $0 } + bundles
            + (env["PATH"] ?? "").split(separator: ":").map { String($0)+"/codex" }
            + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex", home + "/.npm-global/bin/codex"]
        #endif
    }

    private func start() {
        let candidates = [overrideExecutable].compactMap { $0 }
            + Self.executableCandidates(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            fail("clientMissing"); return
        }
        executable = path
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["app-server", "--stdio"]
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.standardInput = stdin; p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        generation = UUID(); let token = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if data.isEmpty { self.fail("disconnected"); return }
                self.receive(data)
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.fail("serviceStopped")
            }
        }
        process = p; input = stdin; output = stdout; inFlight = true; publishDiagnostics()
        do {
            try p.run()
            armTimeout()
            send(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "codex_usage_widget", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"],
                "capabilities": ["experimentalApi": true]]])
        } catch { fail("startFailed") }
    }
    private func send(_ object: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input?.fileHandleForWriting.write(contentsOf: data)
        } catch { fail("sendFailed") }
    }
    private var heldLimits: LimitsResponse?
    private var accountReadDone = false

    private func deliver(_ limits: LimitsResponse) {
        guard let identity = limits.accountId.map({ Self.hash($0) }) ?? accountIdentity else {
            fail("loginRequired"); return
        }
        timeout?.invalidate(); failures = 0; lastFailureCode = nil
        lastQuotaSuccessAt = Date().timeIntervalSince1970
        pendingTokenAccount = identity
        onResult?(limits, identity); publishDiagnostics()
        armTimeout()
        lastTokenAttemptAt = Date().timeIntervalSince1970
        lastTokenAttemptAccountKey = identity
        lastTokenErrorCode = nil; publishDiagnostics()
        send(["id": 4, "method": "account/usage/read", "params": [:]])
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 8 * 1024 * 1024 else { fail("responseTooLarge"); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            // Ignore unrelated notifications and server requests: this client only reads account limits.
            guard let id = json["id"] as? Int, (1...4).contains(id) else { continue }
            if id == 4, pendingTokenAccount != nil, json["error"] != nil { finishTokens(nil, errorCode: "tokenReadFailed"); continue }
            if json["error"] != nil { fail("readFailed"); return }
            guard let result = json["result"] as? [String: Any] else {
                if id == 4 { finishTokens(nil, errorCode: "invalidTokenResponse") }; continue
            }
            switch id {
            case 1:
                timeout?.invalidate(); ready = true; inFlight = false
                publishDiagnostics()
                send(["method": "initialized"]); refresh()
            case 2:
                let account = result["account"] as? [String: Any]
                let identity = (account?["id"] as? String) ?? (account?["email"] as? String)
                accountIdentity = identity.map { Self.hash($0) }
                accountReadDone = true
                // Limits that arrived first without an account ID were held for this identity.
                if let held = heldLimits { heldLimits = nil; deliver(held) }
            case 3:
                guard let bytes = try? JSONSerialization.data(withJSONObject: result),
                      let limits = try? JSONDecoder().decode(LimitsResponse.self, from: bytes) else { fail("invalidQuota"); return }
                if limits.accountId == nil && !accountReadDone { heldLimits = limits; continue }
                deliver(limits)
            case 4:
                let bytes = try? JSONSerialization.data(withJSONObject: result)
                let usage = bytes.flatMap { try? JSONDecoder().decode(TokenUsageResponse.self, from: $0) }
                finishTokens(usage?.summary?.lifetimeTokens, errorCode: usage?.summary?.lifetimeTokens == nil ? "tokenUnavailable" : nil)
            default: break
            }
        }
    }
    private func finishTokens(_ total: Double?, errorCode: String? = nil) {
        guard let account = pendingTokenAccount else { return }
        pendingTokenAccount = nil; timeout?.invalidate(); inFlight = false
        let validTotal = total.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if validTotal != nil {
            lastTokenSuccessAt = Date().timeIntervalSince1970; lastTokenErrorCode = nil; tokenFailures = 0
            lastTokenSuccessAccountKey = account
        } else {
            lastTokenErrorCode = errorCode ?? "invalidTokenCount"; tokenFailures += 1
        }
        onTokens?(validTotal, account)
        schedule(after: pollInterval)
    }
    private static func hash(_ value: String) -> String {
        Portable.sha256Hex(value)
    }
    private func armTimeout() {
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: requestTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.pendingTokenAccount != nil {
                self.finishTokens(nil, errorCode: "tokenTimeout")
                self.disconnect() // Tokens are optional; a token timeout must not invalidate fresh quota.
            } else { self.fail("timeout") }
        }
    }
    private func fail(_ message: String) {
        guard !stopping, !suspended else { return }
        if pendingTokenAccount != nil { finishTokens(nil, errorCode: message) }
        disconnect(); failures += 1; lastFailureCode = message; onFailure?(message)
        schedule(after: min(300, retryBase * pow(2, Double(min(failures-1, 5)))))
    }
    private func schedule(after interval: Double) {
        retryTimer?.invalidate()
        nextAttemptAt = Date().timeIntervalSince1970 + interval
        publishDiagnostics()
        retryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in self?.refresh() }
    }
    private func disconnect() {
        generation = UUID(); timeout?.invalidate()
        output?.fileHandleForReading.readabilityHandler = nil
        let old = process; old?.terminationHandler = nil
        try? input?.fileHandleForWriting.close()
        if let old, old.isRunning {
            old.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now()+2) {
                if old.isRunning { forceKill(old) }
            }
        }
        pendingTokenAccount = nil; process = nil; input = nil; output = nil; ready = false; inFlight = false; buffer = Data()
        publishDiagnostics()
    }
    private func publishDiagnostics() {
        onDiagnostics?(diagnostics)
    }
}
