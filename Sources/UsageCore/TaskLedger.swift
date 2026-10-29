import Foundation

public enum TaskOutcome: String, Codable, CaseIterable {
    case accepted
    case needsWork
    case failed
    case notRun
    case interrupted
    case abandoned
}

public struct ObservedQuotaWindow: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public init(id: String, name: String, usedPercent: Double,
                windowDurationMins: Int?, resetsAt: Double?) {
        self.id = id
        self.name = name
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

/// Account-level observations captured at task boundaries. These are context only;
/// the values are never converted into task-attributed usage.
public struct AccountUsageSnapshot: Codable, Equatable, Identifiable {
    public let id: String
    public let capturedAt: Double
    public let accountKey: String?
    public let quotaObservedAt: Double?
    public let quotaHealth: SourceHealth
    public let quotaWindows: [ObservedQuotaWindow]
    public let accountTokenTotal: Double?
    public let tokenObservedAt: Double?
    public let tokenHealth: SourceHealth

    public init(id: String = UUID().uuidString, capturedAt: Double,
                accountKey: String?, quotaObservedAt: Double?, quotaHealth: SourceHealth,
                quotaWindows: [ObservedQuotaWindow], accountTokenTotal: Double?,
                tokenObservedAt: Double?, tokenHealth: SourceHealth) {
        self.id = id
        self.capturedAt = capturedAt
        self.accountKey = accountKey
        self.quotaObservedAt = quotaObservedAt
        self.quotaHealth = quotaHealth
        self.quotaWindows = quotaWindows
        self.accountTokenTotal = accountTokenTotal
        self.tokenObservedAt = tokenObservedAt
        self.tokenHealth = tokenHealth
    }
}

public enum ObservedPeriodChange: Equatable {
    case change(Double)
    case reset
    case unavailable
    case accountChanged
}

public func observedQuotaChange(from start: AccountUsageSnapshot?, to end: AccountUsageSnapshot?, windowID: String) -> ObservedPeriodChange {
    guard let start, let end else { return .unavailable }
    guard start.quotaHealth == .fresh, end.quotaHealth == .fresh else { return .unavailable }
    guard let startAccount = start.accountKey, let endAccount = end.accountKey else { return .unavailable }
    guard startAccount == endAccount else { return .accountChanged }
    guard let first = start.quotaWindows.first(where: { $0.id == windowID }),
          let last = end.quotaWindows.first(where: { $0.id == windowID }) else { return .unavailable }
    guard first.windowDurationMins == last.windowDurationMins, sameReset(first.resetsAt, last.resetsAt),
          last.usedPercent >= first.usedPercent else { return .reset }
    return .change(last.usedPercent - first.usedPercent)
}

public func observedTokenCounterChange(from start: AccountUsageSnapshot?, to end: AccountUsageSnapshot?) -> ObservedPeriodChange {
    guard let start, let end else { return .unavailable }
    guard start.tokenHealth == .fresh, end.tokenHealth == .fresh else { return .unavailable }
    guard let startAccount = start.accountKey, let endAccount = end.accountKey else { return .unavailable }
    guard startAccount == endAccount else { return .accountChanged }
    guard let first = start.accountTokenTotal, let last = end.accountTokenTotal,
          first.isFinite, last.isFinite, first >= 0, last >= 0 else { return .unavailable }
    guard last >= first else { return .reset }
    return .change(last - first)
}

public struct TaskRecord: Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let project: String?
    public let issue: String?
    public let model: String?
    public let reasoning: String?
    public let startedAt: Double
    public var endedAt: Double?
    public var retries: Int?
    public var outcome: TaskOutcome?
    public var validationNotes: String?
    public let startSnapshotID: String?
    public var endSnapshotID: String?
    /// Populated only by a future source that can prove direct session attribution.
    public var attributedSessionTokens: Double? = nil

    public var isActive: Bool { endedAt == nil }
    public var durationSeconds: Double? {
        guard let endedAt, endedAt >= startedAt else { return nil }
        return endedAt - startedAt
    }

    public init(id: String = UUID().uuidString, title: String, project: String?, issue: String?,
                model: String?, reasoning: String?, startedAt: Double, endedAt: Double? = nil,
                retries: Int? = nil, outcome: TaskOutcome? = nil, validationNotes: String? = nil,
                startSnapshotID: String?, endSnapshotID: String? = nil,
                attributedSessionTokens: Double? = nil) {
        self.id = id
        self.title = title
        self.project = project
        self.issue = issue
        self.model = model
        self.reasoning = reasoning
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.retries = retries
        self.outcome = outcome
        self.validationNotes = validationNotes
        self.startSnapshotID = startSnapshotID
        self.endSnapshotID = endSnapshotID
        self.attributedSessionTokens = attributedSessionTokens
    }
}

public struct TaskLedger: Codable, Equatable {
    public private(set) var records: [TaskRecord] = []
    public init() {}

    public var activeTask: TaskRecord? { records.last(where: \.isActive) }

    public mutating func start(title: String, project: String?, issue: String?, model: String?,
                               reasoning: String?, snapshotID: String?, now: Double) throws {
        guard activeTask == nil else { throw TaskLedgerError.taskAlreadyActive }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, normalizedTitle.count <= 500, now.isFinite else {
            throw TaskLedgerError.invalidTask
        }
        records.append(TaskRecord(title: normalizedTitle, project: Self.clean(project), issue: Self.clean(issue),
                                  model: Self.clean(model), reasoning: Self.clean(reasoning), startedAt: now,
                                  startSnapshotID: snapshotID))
        trim()
    }

    public mutating func finish(retries: Int, outcome: TaskOutcome, validationNotes: String?,
                                snapshotID: String?, now: Double) throws {
        guard let index = records.lastIndex(where: \.isActive) else { throw TaskLedgerError.noActiveTask }
        guard retries >= 0, retries <= 10_000, now.isFinite, now >= records[index].startedAt else {
            throw TaskLedgerError.invalidCompletion
        }
        records[index].endedAt = now
        records[index].retries = retries
        records[index].outcome = outcome
        records[index].validationNotes = Self.clean(validationNotes)
        records[index].endSnapshotID = snapshotID
        trim()
    }

    private mutating func trim() {
        let maximumRecords = 5_000
        if records.count > maximumRecords { records = Array(records.suffix(maximumRecords)) }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        return String(result.prefix(2_000))
    }
}

public enum TaskLedgerError: Error, Equatable {
    case taskAlreadyActive
    case noActiveTask
    case invalidTask
    case invalidCompletion
}

public struct AccountObservationLedger: Codable, Equatable {
    public private(set) var snapshots: [AccountUsageSnapshot] = []
    public init() {}

    public mutating func append(_ snapshot: AccountUsageSnapshot) {
        snapshots.append(snapshot)
        let maximumSnapshots = 10_000
        if snapshots.count > maximumSnapshots { snapshots = Array(snapshots.suffix(maximumSnapshots)) }
    }

    public func snapshot(id: String?) -> AccountUsageSnapshot? {
        guard let id else { return nil }
        return snapshots.last(where: { $0.id == id })
    }
}

public struct TaskLedgerExport: Codable {
    public let schemaVersion: Int
    public let exportedAt: Double
    public let taskLedger: TaskLedger
    public let accountObservations: AccountObservationLedger

    public init(exportedAt: Double, taskLedger: TaskLedger, accountObservations: AccountObservationLedger) {
        schemaVersion = 1
        self.exportedAt = exportedAt
        self.taskLedger = taskLedger
        self.accountObservations = accountObservations
    }
}
