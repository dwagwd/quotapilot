import Foundation

/// When each quota window was first seen at its limit, kept in a small JSON file in the shared state
/// directory so the app (which records sightings) and the CLI (which shares them) read the same data.
/// Keys are `<window id>|<reset time in minutes>`; the value is the first-seen time in seconds.
public enum LimitSightings {
    public static let fileName = "limit-since.json"
    /// Some providers' reset times drift by seconds between polls; resets this close are the same period.
    public static let resetTolerance: Double = 5 * 60

    public static func fileURL(in directory: URL = Portable.stateDirectory()) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Key for a window's period: id and reset time rounded to the minute.
    public static func key(_ windowID: String, _ resetsAt: Double) -> String {
        windowID + "|" + String(Int((resetsAt / 60).rounded()))
    }

    private struct Entry { let key: String; let reset: Double; let since: Double }

    private static func entries(_ map: [String: Double], windowID: String, near reset: Double) -> [Entry] {
        map.compactMap { key, since in
            guard let bar = key.lastIndex(of: "|"), String(key[..<bar]) == windowID,
                  let minute = Double(key[key.index(after: bar)...]) else { return nil }
            let entryReset = minute * 60
            guard abs(entryReset - reset) <= resetTolerance else { return nil }
            return Entry(key: key, reset: entryReset, since: since)
        }
    }

    public static func load(from url: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return map.filter { $0.value.isFinite }
    }

    @discardableResult
    public static func save(_ map: [String: Double], to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(map) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }

    /// Forgets windows whose reset time has passed.
    public static func prune(_ map: [String: Double], now: Double) -> [String: Double] {
        map.filter { key, since in
            guard since.isFinite, let bar = key.lastIndex(of: "|"),
                  let minute = Double(key[key.index(after: bar)...]) else { return false }
            return minute * 60 > now
        }
    }

    /// Two maps in one; the earliest first-seen time wins for a shared key.
    public static func merge(_ map: [String: Double], with other: [String: Double]) -> [String: Double] {
        map.merging(other) { min($0, $1) }
    }

    /// Notes that a window is at its limit. An existing entry for the same window whose reset is within the
    /// tolerance is reused (earliest first-seen time kept); otherwise a new one starts at `now`.
    public static func record(_ map: [String: Double], windowID: String, resetsAt: Double, now: Double) -> [String: Double] {
        var map = map
        let matches = entries(map, windowID: windowID, near: resetsAt)
        guard let earliest = matches.map(\.since).min(), let latestMatch = matches.map(\.reset).max() else {
            map[key(windowID, resetsAt)] = now
            return map
        }
        for match in matches { map[match.key] = nil }
        // The entry follows the latest reset seen, so pruning does not drop it before the window really resets.
        map[key(windowID, max(resetsAt, latestMatch))] = earliest
        return map
    }

    /// When the window was first seen at its limit, with the same reset tolerance as `record`.
    public static func lookup(_ map: [String: Double], windowID: String, resetsAt: Double) -> Double? {
        entries(map, windowID: windowID, near: resetsAt).map(\.since).min()
    }
}
