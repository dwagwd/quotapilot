import Foundation

/// Detects a Codex quota window that hit its limit and later reset, so an interrupted session can be resumed.
/// A reset is confirmed only by a fresh backend reading below 100%; a passing reset time alone is not enough.
public struct AutoContinuePlanner {
    public enum Action: Equatable { case none, resume(blockedSince: Double) }
    private var blockedSince: [String: Double] = [:]
    public init() {}
    public var isBlocked: Bool { !blockedSince.isEmpty }

    public mutating func observe(windowID: String, used: Double?, limitReached: Bool, now: Double) -> Action {
        let full = limitReached || (used.map { $0.isFinite && $0 >= 100 } ?? false)
        if full {
            if blockedSince[windowID] == nil { blockedSince[windowID] = now }
            return .none
        }
        guard let used, used.isFinite, (0..<100).contains(used), let since = blockedSince.removeValue(forKey: windowID) else { return .none }
        // Another window may still be exhausted; resuming would hit the limit again.
        return blockedSince.isEmpty ? .resume(blockedSince: since) : .none
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

    /// The most recently written top-level session that was active when the limit was reached.
    public static func interruptedSession(root: URL, blockedSince: Double, now: Double,
                                          activityMargin: Double = 900) -> CodexSessionReference? {
        let base = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [], options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [(String, Double)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            var info = stat()
            guard stat(url.path, &info) == 0 else { continue }
            let modified = Double(info.st_mtimespec.tv_sec)
            if modified >= blockedSince - activityMargin && modified <= now { candidates.append((url.path, modified)) }
        }
        for (path, modified) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            let head = (try? handle.read(upToCount: 1_048_576)) ?? Data()
            try? handle.close()
            guard let newline = head.firstIndex(of: 0x0A),
                  let line = String(data: head[head.startIndex..<newline], encoding: .utf8),
                  let reference = reference(firstLine: line, modifiedAt: modified) else { continue }
            return reference
        }
        return nil
    }
}

public let autoContinueDefaultPrompt = "The Codex usage limit has reset. Continue the previous task from where it stopped. If it is already complete, reply that it is complete and do nothing else."
