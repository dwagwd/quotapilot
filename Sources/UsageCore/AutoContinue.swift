import Foundation

/// Detects a Codex quota window that hit its limit and later reset, so an interrupted session can be resumed.
/// A reset is confirmed only by a fresh backend reading below 100%; a passing reset time alone is not enough.
public struct AutoContinuePlanner {
    public enum Action: Equatable {
        case none
        /// A new exhaustion episode started; capture the interrupted session now, before newer sessions appear.
        case blocked(since: Double)
        case resume(blockedSince: Double)
    }
    public struct Window: Equatable {
        public let id: String
        public let used: Double?
        public let limitReached: Bool
        public init(id: String, used: Double?, limitReached: Bool) { self.id = id; self.used = used; self.limitReached = limitReached }
    }
    private var blockedSince: [String: Double] = [:]
    private var episodeStart: Double?
    private var episodeAccount: String?
    public init() {}
    public var isBlocked: Bool { !blockedSince.isEmpty }

    /// Single-window observation, kept for callers that only track one window.
    public mutating func observe(windowID: String, used: Double?, limitReached: Bool, now: Double) -> Action {
        observe(windows: [Window(id: windowID, used: used, limitReached: limitReached)], account: episodeAccount, now: now, requireAllFresh: false)
    }

    /// Processes a whole backend response before deciding. Resume fires only when no window is exhausted,
    /// every window in the response has a fresh reading, and the response belongs to the account that was blocked.
    public mutating func observe(windows: [Window], account: String?, now: Double, requireAllFresh: Bool = true) -> Action {
        if episodeStart != nil, account != episodeAccount {
            // A different account answered; the old episode cannot be resumed from this reading.
            blockedSince.removeAll(); episodeStart = nil; episodeAccount = nil
        }
        var allFresh = !windows.isEmpty
        for window in windows {
            let used = window.used.flatMap { $0.isFinite ? $0 : nil }
            if window.limitReached || (used.map { $0 >= 100 } ?? false) {
                if blockedSince[window.id] == nil { blockedSince[window.id] = now }
            } else if let used, used >= 0 {
                blockedSince.removeValue(forKey: window.id)
            } else {
                allFresh = false
            }
        }
        if episodeStart == nil {
            guard let first = blockedSince.values.min() else { return .none }
            episodeStart = first; episodeAccount = account
            return .blocked(since: first)
        }
        guard let start = episodeStart, blockedSince.isEmpty, allFresh || !requireAllFresh else { return .none }
        episodeStart = nil; episodeAccount = nil
        return .resume(blockedSince: start)
    }
}

public struct CodexSessionReference: Equatable {
    public let id: String
    public let cwd: String
    public let modifiedAt: Double
}

public enum CodexSessionLocator {
    /// Parses the `session_meta` first line of a Codex rollout file.
    public static func reference(firstLine: String, modifiedAt: Double) -> CodexSessionReference? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String, !id.isEmpty,
              let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        // Sub-agent threads are resumed through their parent session.
        if let parent = payload["parent_thread_id"] as? String, !parent.isEmpty { return nil }
        return CodexSessionReference(id: id, cwd: cwd, modifiedAt: modifiedAt)
    }

    public enum Attribution: Equatable {
        case session(CodexSessionReference)
        /// More than one top-level session was active when the limit was reached; the user has to choose.
        case ambiguous([CodexSessionReference])
        case none
    }

    /// Top-level sessions written within `activityMargin` before `at` (and not after it), newest first.
    public static func activeSessions(root: URL, at: Double, activityMargin: Double = 900) -> [CodexSessionReference] {
        let base = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [], options: [.skipsHiddenFiles]) else { return [] }
        var candidates: [(String, Double)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let modified = Portable.status(url.path)?.modified else { continue }
            if modified >= at - activityMargin && modified <= at { candidates.append((url.path, modified)) }
        }
        var references: [CodexSessionReference] = []
        for (path, modified) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            let head = (try? handle.read(upToCount: 1_048_576)) ?? Data()
            try? handle.close()
            guard let newline = head.firstIndex(of: 0x0A),
                  let line = String(data: head[head.startIndex..<newline], encoding: .utf8),
                  let reference = reference(firstLine: line, modifiedAt: modified),
                  !references.contains(where: { $0.id == reference.id }) else { continue }
            references.append(reference)
        }
        return references
    }

    /// The session that was running when the limit was observed. Call this when the limit is first seen, not at
    /// reset time: sessions started later must never be mistaken for the interrupted one.
    public static func interruptedSession(root: URL, blockedSince: Double, activityMargin: Double = 900) -> Attribution {
        let sessions = activeSessions(root: root, at: blockedSince, activityMargin: activityMargin)
        switch sessions.count {
        case 0: return .none
        case 1: return .session(sessions[0])
        default: return .ambiguous(sessions)
        }
    }
}

public let autoContinueDefaultPrompt = "The Codex usage limit has reset. Continue the previous task from where it stopped. If it is already complete, reply that it is complete and do nothing else."
