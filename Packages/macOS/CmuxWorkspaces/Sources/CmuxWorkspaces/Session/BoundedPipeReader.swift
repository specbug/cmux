import Foundation

/// Drains a pipe on a background queue, keeping at most `limit` bytes.
///
/// Reading concurrently with the child prevents a full pipe buffer from
/// stalling it; the cap keeps an unexpected flood from growing memory.
final class BoundedPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(pipe: Pipe, limit: Int = 64 * 1024) {
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                if data.count < limit {
                    data.append(chunk.prefix(limit - data.count))
                }
                lock.unlock()
            }
            done.signal()
        }
    }

    /// Waits briefly for end-of-file and returns the captured text.
    func finish() -> String {
        _ = done.wait(timeout: .now() + 1)
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
