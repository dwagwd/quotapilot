import Foundation

/// When the opt-in daily share may run again.
public enum AutoShareSchedule {
    /// One attempt a day (with a little slack for the hourly tick).
    public static let interval: Double = 86400 - 600
    /// A full collector is not this Mac's fault: try again after about this long.
    public static let fullRetryDelay: Double = 3 * 3600

    public static func isDue(lastAttempt: Double, now: Double) -> Bool { now - lastAttempt >= interval }

    /// The `lastAutoShare` value that makes the next attempt come `fullRetryDelay` after `now`.
    public static func retryStamp(after now: Double) -> Double { now - interval + fullRetryDelay }

    /// True when the collector said it is full: the `full` flag, or (fallback) a 429 with its fixed message.
    public static func isCollectorFull(_ failure: ShareFailure) -> Bool {
        failure.collectorFull
            || (failure.status == 429 && failure.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "collector is full for today")
    }
}
