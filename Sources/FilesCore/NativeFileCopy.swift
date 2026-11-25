import Foundation
import Darwin

/// Logical data-fork bytes staged for the current source item, before content verification.
/// Clone operations may finish without intermediate data callbacks. This is not device I/O throughput.
public struct LiveTransferProgress: Sendable {
    public let bytes: Int64
    public let totalBytes: Int64?
    public let seconds: Double
}

enum NativeFileCopy {
    static func run(from source: URL, to destination: URL, totalBytes: Int64?,
                    cancellation: CopyCancellation, allowClone: Bool = true,
                    progress: @escaping @Sendable (LiveTransferProgress) -> Void) throws {
        try cancellation.check()
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = NativeCopyProgress(totalBytes: totalBytes, cancellation: cancellation, progress: progress)
        let callback: copyfile_callback_t = { what, stage, state, source, destination, opaque in
            guard let opaque else { return COPYFILE_QUIT }
            let context = Unmanaged<NativeCopyProgress>.fromOpaque(opaque).takeUnretainedValue()
            // Preserve the native error; observers must not turn errors into skipped entries.
            if stage == COPYFILE_ERR { return COPYFILE_QUIT }
            if context.cancellation.isCancelled { return COPYFILE_QUIT }
            if let source, let state, what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var bytes: off_t = 0
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes) == 0 {
                    context.record(String(cString: source), bytes: bytes)
                }
            } else if let source, let destination, what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
                // Successful APFS clones have no data callbacks. Count their logical data, not physical I/O.
                var entry = stat()
                if lstat(destination, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG {
                    context.record(String(cString: source), bytes: entry.st_size)
                }
            }
            return context.cancellation.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), opaque) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                                 unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW | COPYFILE_DATA_SPARSE)
        if allowClone { flags |= copyfile_flags_t(COPYFILE_CLONE) }
        context.emit(force: true)
        try cancellation.check()
        let result = copyfile(source.path, destination.path, state, flags)
        let failure = errno
        try cancellation.check()
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        // The non-recursive clone of a single file can omit every callback.
        var entry = stat()
        if lstat(destination.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG {
            context.record(source.path, bytes: entry.st_size)
        }
        context.emit(force: true)
        try cancellation.check()
    }
}

/// copyfile invokes callbacks synchronously on the calling thread. No state escapes that call.
private final class NativeCopyProgress {
    let cancellation: CopyCancellation
    private let progress: @Sendable (LiveTransferProgress) -> Void
    private let totalBytes: Int64?
    private let started = ContinuousClock.now
    private var lastEmission: ContinuousClock.Instant?
    private var emittedData = false
    private var files: [String: Int64] = [:]
    private var bytes: Int64 = 0

    init(totalBytes: Int64?, cancellation: CopyCancellation,
         progress: @escaping @Sendable (LiveTransferProgress) -> Void) {
        self.totalBytes = totalBytes; self.cancellation = cancellation; self.progress = progress
    }
    func record(_ path: String, bytes value: Int64) {
        guard value >= 0 else { return }
        let old = files[path] ?? 0
        guard value > old else { return }
        files[path] = value
        let (sum, overflow) = bytes.addingReportingOverflow(value - old)
        bytes = overflow ? .max : sum
        emit(force: !emittedData)
        emittedData = true
    }
    func emit(force: Bool) {
        let now = ContinuousClock.now
        guard force || lastEmission.map({ $0.duration(to: now) >= .milliseconds(100) }) != false else { return }
        lastEmission = now
        let time = started.duration(to: now).components
        let seconds = Double(time.seconds) + Double(time.attoseconds) / 1e18
        // A changing source must not produce a false percentage against the earlier plan.
        let total = totalBytes.flatMap { $0 >= bytes && $0 >= 0 ? $0 : nil }
        progress(LiveTransferProgress(bytes: bytes, totalBytes: total, seconds: seconds))
    }
}
