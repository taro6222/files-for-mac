import Foundation

/// A read-only journal snapshot. Recovery always reopens and verifies the record and files.
public struct SevenZipSplitJournalSummary: Sendable, Identifiable {
    public var id: URL { journal }
    public let journal: URL
    public let destination: URL?
    public let staging: URL?
    public let phase: String
    public let ambiguousIntent: Bool
    public let updatedAt: Date

    public var isUnfinished: Bool { !["committed", "rolledBack"].contains(phase) || staging != nil }
    public var canAttemptRecovery: Bool {
        !ambiguousIntent && ["prepared", "publishing", "discarding"].contains(phase)
    }
}
