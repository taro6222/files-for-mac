import Foundation
import Darwin

/// Choices and automatic dictionary sizes follow Files v4.2.9's MIT-licensed
/// CreateArchiveDialog. Memory is an estimate, not an allocation limit.
public struct SevenZipCompressionOptions: Codable, Equatable, Sendable {
    public static let dictionarySizes = [0, 64 << 10, 256 << 10] + (0...10).map { (1 << 20) << $0 }
    public static let wordSizes = [0, 8, 16, 32, 64, 128, 256, 273]
    public static let maximumThreads = 512 // 256 SDK block encoders, up to two threads each.
    public static var hostThreadCount: Int { min(max(1, ProcessInfo.processInfo.activeProcessorCount), maximumThreads) }
    /// Zero selects the automatic value for the chosen compression level.
    public let dictionarySize: Int, wordSize: Int, threadCount: Int
    public init(dictionarySize: Int = 0, wordSize: Int = 0, threadCount: Int = 2) {
        self.dictionarySize = dictionarySize; self.wordSize = wordSize; self.threadCount = threadCount
    }
    public var isValid: Bool {
        Self.dictionarySizes.contains(dictionarySize) && Self.wordSizes.contains(wordSize) && (1...Self.maximumThreads).contains(threadCount)
    }
    public func effectiveDictionarySize(for level: ArchiveCompressionLevel) -> Int {
        guard level != .store else { return 0 }
        if dictionarySize != 0 { return dictionarySize }
        switch level {
        case .ultra: return 64 << 20
        case .high: return 32 << 20
        case .normal: return 16 << 20
        case .low: return 1 << 20
        case .fast: return 64 << 10
        case .store: return 0
        }
    }
    public func effectiveWordSize(for level: ArchiveCompressionLevel) -> Int {
        guard level != .store else { return 0 }
        return wordSize == 0 ? (level.rawValue >= 7 ? 64 : 32) : wordSize
    }
    /// Files' LZMA2 estimate: (dictionary * 11.5 + 6 MiB) * ceil(threads / 2).
    /// Small inputs can reduce actual dictionaries/encoders; buffers and SDK overhead vary.
    public func estimatedMemoryBytes(for level: ArchiveCompressionLevel) -> UInt64? {
        guard isValid else { return nil }
        if level == .store { return 1 << 20 }
        let dictionary = UInt64(effectiveDictionarySize(for: level))
        return (dictionary * 23 / 2 + (6 << 20)) * UInt64((threadCount + 1) / 2)
    }
    /// A current system snapshot, counting free and inactive (potentially reclaimable) pages.
    /// This is not a promise that an allocation will succeed; wired/compressed pages are excluded.
    public static func availableMemoryEstimate() -> UInt64? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { _ = mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        return (UInt64(info.free_count) + UInt64(info.inactive_count)) * UInt64(pageSize)
    }
}
