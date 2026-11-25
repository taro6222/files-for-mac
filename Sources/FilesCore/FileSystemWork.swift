import Foundation

/// Synchronous metadata calls may wait for a provider or server. They must not occupy Swift's cooperative pool.
public enum FileSystemWork {
    public static func run<Value: Sendable>(qos: DispatchQoS.QoSClass,
                                    _ operation: @escaping @Sendable (CopyCancellation) throws -> Value) async throws -> Value {
        let state = FileSystemWorkState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                DispatchQueue.global(qos: qos).async {
                    state.complete(Result { try state.cancellation.check(); return try operation(state.cancellation) })
                }
            }
        } onCancel: { state.cancel() }
    }
}

private final class FileSystemWorkState<Value: Sendable>: @unchecked Sendable {
    let cancellation = CopyCancellation()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let cancelled = lock.withLock {
            if cancellation.isCancelled { return true }
            self.continuation = continuation; return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }
    func complete(_ result: Result<Value, Error>) {
        let waiting = lock.withLock { let waiting = continuation; continuation = nil; return waiting }
        waiting?.resume(with: result)
    }
    func cancel() { cancellation.cancel(); complete(.failure(CancellationError())) }
}
