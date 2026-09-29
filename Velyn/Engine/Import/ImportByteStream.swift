import Foundation

/// Bridges serial resource callbacks to a file without buffering an entire original.
/// All mutable state, including file operations, is protected by lock. Callers must
/// invoke append/finish off MainActor. Completion may precede waiter registration.
final class ImportByteStream: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var outcome: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ImportFailure.storageFailure }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        do { try handle.write(contentsOf: data); lock.unlock() }
        catch { lock.unlock(); finish(error: error) }
    }

    func finish(error: Error? = nil) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        var result: Result<Void, Error>
        if let error { result = .failure(error) }
        else {
            do { try handle.synchronize(); result = .success(()) }
            catch { result = .failure(error) }
        }
        do { try handle.close() }
        catch { if case .success = result { result = .failure(error) } }
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { waiting in
            lock.lock()
            if let outcome { lock.unlock(); waiting.resume(with: outcome) }
            else { continuation = waiting; lock.unlock() }
        }
    }
}
