import CryptoKit
import Foundation

/// Downloads one large model file with progress, verifies its SHA-256, and moves it into place atomically.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case http(Int)
        case checksumMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .http(let status): "The model download failed (HTTP \(status))."
            case .checksumMismatch: "The downloaded model is corrupt (checksum mismatch). Try again."
            }
        }
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: (@Sendable (Double) -> Void)?
    private var expectedBytes: Int64
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    private init(expectedBytes: Int64, progress: (@Sendable (Double) -> Void)?) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    /// Fetches `remote` to `destination`, reporting 0…1 progress, and throws unless the bytes hash to `sha256`.
    static func fetch(_ remote: URL, to destination: URL, sha256: String, expectedBytes: Int64,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let downloader = ModelDownloader(expectedBytes: expectedBytes, progress: progress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let staged: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: remote)
                let cancelled = downloader.lock.withLock { () -> Bool in
                    downloader.continuation = continuation
                    downloader.task = task
                    return downloader.cancelled
                }
                if cancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            let task = downloader.lock.withLock { () -> URLSessionDownloadTask? in
                downloader.cancelled = true
                return downloader.task
            }
            task?.cancel()
        }
        defer { try? FileManager.default.removeItem(at: staged) }

        let actual = try sha256Hex(of: staged)
        guard actual == sha256.lowercased() else { throw Failure.checksumMismatch(expected: sha256, actual: actual) }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staged, to: destination)
        // Re-downloadable, so keep it out of device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = destination
        try? marked.setResourceValues(values)
        progress?(1)
    }

    /// Streams a file through SHA-256 without loading it into memory.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        guard total > 0 else { return }
        progress?(min(0.99, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(Failure.http(http.statusCode)))
            return
        }
        // `location` is deleted when this method returns, so move it somewhere we own first.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            finish(.success(staged))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
