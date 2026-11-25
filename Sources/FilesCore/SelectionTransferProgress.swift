import Foundation

/// Logical data staged across selected copy roots, before verification/publication.
/// Failed attempts may contribute bytes; this is not an operation success percentage or device I/O.
public struct SelectionTransferProgress: Codable, Sendable {
    public let bytes: Int64
    public let totalBytes: Int64?
    public let seconds: Double
    /// Orders asynchronous deliveries, including denominator corrections after a skipped conflict.
    public let sequence: UInt64
}

final class SelectionTransferTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [Int64?]
    private var staged: [Int64]
    private var sequence: UInt64 = 0
    private let started = ContinuousClock.now
    init(plans: [Int64?]) { self.plans = plans; staged = Array(repeating: 0, count: plans.count) }
    func excludeUnstaged(_ index: Int) {
        lock.withLock { if staged[index] == 0 { plans[index] = 0 } }
    }
    func record(_ index: Int, live: LiveTransferProgress) -> SelectionTransferProgress {
        lock.withLock {
            staged[index] = max(staged[index], live.bytes)
            plans[index] = live.totalBytes
            return snapshotLocked()
        }
    }
    func snapshot() -> SelectionTransferProgress { lock.withLock { snapshotLocked() } }
    private func snapshotLocked() -> SelectionTransferProgress {
        sequence += 1
        var bytes: Int64 = 0
        var total: Int64? = 0
        for index in staged.indices {
            let (sum, overflow) = bytes.addingReportingOverflow(staged[index])
            bytes = overflow ? .max : sum
            if overflow { total = nil }
            if let known = total, let planned = plans[index], planned >= staged[index] {
                let (next, overflow) = known.addingReportingOverflow(planned)
                total = overflow ? nil : next
            } else { total = nil }
        }
        let time = started.duration(to: .now).components
        return SelectionTransferProgress(bytes: bytes, totalBytes: total,
            seconds: Double(time.seconds) + Double(time.attoseconds) / 1e18, sequence: sequence)
    }
}
