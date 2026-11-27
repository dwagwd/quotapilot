import Foundation

/// Claude Code's OAuth login as used for the plan-usage request.
public struct ClaudeLogin: Equatable {
    public let token: String
    public let plan: String?
    public let expiresAt: Double?
    public init(token: String, plan: String?, expiresAt: Double?) { self.token = token; self.plan = plan; self.expiresAt = expiresAt }
}

/// Decides when Claude Code's keychain item may be read, so macOS asks as rarely as possible.
///
/// Claude Code rewrites its `Claude Code-credentials` item whenever it refreshes its token, and a rewrite can drop the
/// "Always Allow" entry, so every read after a rewrite may show a permission prompt. The rules here:
/// - The credentials file (`~/.claude/.credentials.json`) is checked first; reading it never prompts.
/// - The token is kept in memory (never on disk) until shortly before its `expiresAt`; nothing is read before that.
/// - The keychain item's modification time is read without the secret (no prompt). An expired or rejected token is
///   not read again until Claude Code has actually written a new one.
/// - A read that failed (denied, cancelled, `security` unavailable) is not repeated for `backoff` seconds; the UI
///   shows "needs access" and the person retries with `retryNow()`.
public final class ClaudeLoginCache {
    public enum Result: Equatable {
        case login(ClaudeLogin)
        case missing        // no login found
        case expired        // found, but expired or rejected; Claude Code has to refresh it
        case needsAccess    // the keychain read failed or was refused; waiting for the back-off or for a retry
        case busy           // another read is still waiting (for example on a permission prompt)
    }

    public static let backoff: Double = 6 * 3600
    public static let expiryMargin: Double = 60

    private let readFile: () -> Data?
    private let readKeychain: () -> Data?
    private let keychainStamp: () -> String?
    private let now: () -> Double
    private let lock = NSLock()
    private var cached: ClaudeLogin?
    private var lastReadStamp: String?
    private var blockedUntil: Double = 0
    private var refusals = 0
    private var reading = false
    private var lastServedToken: String?
    private var rejectedToken: String?
    private var reads = 0
    /// How many times the keychain secret was read; tests and diagnostics.
    public var keychainReads: Int { lock.lock(); defer { lock.unlock() }; return reads }

    public init(readFile: @escaping () -> Data?, readKeychain: @escaping () -> Data?, keychainStamp: @escaping () -> String?,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.readFile = readFile; self.readKeychain = readKeychain; self.keychainStamp = keychainStamp; self.now = now
    }

    private func usable(_ login: ClaudeLogin, _ t: Double) -> Bool {
        (login.expiresAt ?? .infinity) > t + Self.expiryMargin && login.token != rejectedToken
    }

    private func serve(_ login: ClaudeLogin) -> Result { lastServedToken = login.token; return .login(login) }

    /// The lock only guards the state: `security` may wait for a person to answer a prompt, and no other call
    /// may be held up behind that. A second call while a read is pending returns `.busy`.
    public func login() -> Result {
        lock.lock()
        let t = now()
        var fileExpired = false
        if let data = readFile(), let from = ClaudePlanUsage.credentials(from: data) {
            let login = ClaudeLogin(token: from.token, plan: from.plan, expiresAt: from.expiresAt)
            if usable(login, t) { defer { lock.unlock() }; return serve(login) }
            fileExpired = true
        }
        if let cached, usable(cached, t) { defer { lock.unlock() }; return serve(cached) }
        if reading { lock.unlock(); return .busy }
        if blockedUntil > t { lock.unlock(); return .needsAccess }
        reading = true
        lock.unlock()

        let stamp = keychainStamp()
        var secret: Data?
        let skip = stamp == nil
        let needsRead: Bool = {
            lock.lock(); defer { lock.unlock() }
            // Same item as the one already read: its token is expired or was rejected, and reading it again returns the same.
            return !skip && lastReadStamp != stamp
        }()
        if needsRead { secret = readKeychain() }

        lock.lock(); defer { lock.unlock() }
        reading = false
        guard let stamp else { return fileExpired ? .expired : .missing }
        if !needsRead { return .expired }
        reads += 1
        guard let data = secret else {
            refusals += 1
            // The first refusal waits for the back-off; after a second one nothing asks again until the person retries.
            blockedUntil = refusals >= 2 ? .infinity : t + Self.backoff
            return .needsAccess
        }
        refusals = 0
        lastReadStamp = stamp
        guard let from = ClaudePlanUsage.credentials(from: data) else { cached = nil; return .missing }
        let login = ClaudeLogin(token: from.token, plan: from.plan, expiresAt: from.expiresAt)
        cached = login
        return usable(login, t) ? serve(login) : .expired
    }

    /// The server refused the token (401). The same token is not sent again, wherever it came from; a new one is
    /// picked up when Claude Code writes the item or the credentials file.
    public func reject() {
        lock.lock(); defer { lock.unlock() }
        rejectedToken = lastServedToken
        cached = nil
    }

    /// The person asked to try again: lift the back-off and read the keychain on the next `login()`.
    public func retryNow() {
        lock.lock(); defer { lock.unlock() }
        cached = nil; blockedUntil = 0; lastReadStamp = nil; refusals = 0
    }

    /// Plan usage was switched off: drop the token from memory.
    public func forget() { retryNow() }
}

/// Whether Claude Code's status-line bridge already provides fresh Claude quota, so nothing else has to be read.
public enum ClaudeBridgeSource {
    public static let freshFor: Double = 300

    /// The bridge writes `claude.json` only when the app's own plan snapshot (marked by `claude-plan.active`) is more
    /// than ten minutes old, so a snapshot newer than that marker came from the status line.
    public static func isFresh(snapshotModified: Double?, planMarkerModified: Double?, now: Double) -> Bool {
        guard let snapshot = snapshotModified, snapshot <= now + 5, now - snapshot <= freshFor else { return false }
        return snapshot > (planMarkerModified ?? 0) + 1
    }

    public static func freshSnapshot(directory: URL = Portable.stateDirectory().appendingPathComponent("providers", isDirectory: true),
                                     now: Double = Date().timeIntervalSince1970) -> ProviderSnapshot? {
        func modified(_ name: String) -> Double? {
            (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.modificationDate]
                .flatMap { ($0 as? Date)?.timeIntervalSince1970 }
        }
        let path = directory.appendingPathComponent("claude.json")
        guard isFresh(snapshotModified: modified("claude.json"), planMarkerModified: modified("claude-plan.active"), now: now),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 262144,
              let data = try? Data(contentsOf: path),
              let snapshot = try? JSONDecoder().decode(ProviderSnapshot.self, from: data),
              snapshot.isValid(now: now, expectedProvider: "claude"),
              now - snapshot.updatedAt <= freshFor,
              !snapshot.limits.windows().isEmpty,
              snapshot.limits.windows().allSatisfy({ $0.id.hasPrefix("claude:") }) else { return nil }
        return snapshot
    }
}

/// The system sources: Claude Code's login through `/usr/bin/security` (the way Claude Code reads it itself).
public enum ClaudeKeychain {
    static let service = "Claude Code-credentials"

    /// Runs `security`; gives up (and stops it) after `timeout` seconds, so a prompt nobody answers cannot hang the caller.
    static func run(_ arguments: [String], timeout: Double) -> Data? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        guard done.wait(timeout: .now() + timeout) == .success else { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    /// The secret. Shows the macOS permission prompt when this program is not on the item's access list.
    public static func secret() -> Data? { run(["find-generic-password", "-s", service, "-w"], timeout: 90) }

    /// The item's modification date from its attributes. Does not return the secret and never prompts.
    public static func stamp() -> String? {
        guard let data = run(["find-generic-password", "-s", service], timeout: 10), let text = String(data: data, encoding: .utf8) else { return nil }
        return stampValue(fromAttributes: text) ?? text
    }

    public static func stampValue(fromAttributes text: String) -> String? {
        guard let range = text.range(of: #""mdat"<timedate>=\S+\s+"([^"\\]*)"#, options: .regularExpression) else { return nil }
        let line = String(text[range])
        return line.split(separator: "\"").dropFirst(2).first.map(String.init)
    }

    public static func credentialsFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Data? {
        try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json"))
    }

    /// One cache per process: every caller shares it, so the keychain is read at most once per token lifetime.
    public static let shared = ClaudeLoginCache(readFile: { credentialsFile() }, readKeychain: { secret() }, keychainStamp: { stamp() })
}
