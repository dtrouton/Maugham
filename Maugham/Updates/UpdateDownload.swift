// Maugham/Updates/UpdateDownload.swift
import Foundation

/// Why an update download was refused or failed in a way the updater names
/// itself (a network failure surfaces as the `URLError` it is).
public enum UpdateDownloadError: Error, LocalizedError, Equatable {
    /// The release declared, or the server sent, more than
    /// `UpdateLimits.maxDownloadBytes`. Nothing is left on disk.
    case tooLarge(bytes: Int64, limit: Int64)
    /// The server answered with a non-success HTTP status (a 404 page is not
    /// an update archive).
    case badStatus(Int)
    /// The server redirected the download to a URL that is not https. The
    /// redirect is not followed and nothing is kept.
    case insecureRedirect

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes, let limit):
            let f = ByteCountFormatter()
            f.countStyle = .file
            return "The update is \(f.string(fromByteCount: bytes)), more than the \(f.string(fromByteCount: limit)) Maugham will download."
        case .badStatus(let code):
            return "The update server answered with an error (HTTP \(code))."
        case .insecureRedirect:
            return "The update server sent the download somewhere that isn't secure (not https)."
        }
    }
}

/// Downloads one update archive with a `URLSessionDownloadTask` — the system
/// writes the bytes, so a 30 MB release arrives in seconds (the per-byte
/// `AsyncBytes` loop this replaced took over three minutes for the same file,
/// measured 2026-10-18), retries ONCE on a transient network error (resuming
/// from the bytes already received when the error carries resume data), and
/// cancels the moment the received bytes pass the cap.
///
/// The file lands at the caller's `destination` only once it is complete; a
/// failure leaves nothing there. The caller (`UpdateChecker.defaultDownload`)
/// passes a `.download` temp path and moves it into place itself, so a
/// half-received archive can never sit at the final `Maugham-<ver>.zip` path
/// that a later check would reuse as complete.
public enum UpdateDownload {
    /// How many attempts in all: the first, plus one retry.
    public static let maxAttempts = 2

    /// Errors worth one more try: the connection dropped or never came up, or
    /// the server answered 5xx (its own trouble, often momentary). Everything
    /// else (a refused size, a 4xx, a cancellation, a TLS failure, an
    /// unwritable disk) fails at once.
    public static func isTransient(_ error: Error) -> Bool {
        if case UpdateDownloadError.badStatus(let code)? = error as? UpdateDownloadError {
            return (500...599).contains(code)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// The cap decision, pure. `expectedBytes` is what the server or release
    /// declared (≤ 0 when unknown, which is never a refusal on its own);
    /// `receivedBytes` is what has actually arrived.
    public static func exceedsCap(receivedBytes: Int64, expectedBytes: Int64, limits: UpdateLimits = .standard) -> Bool {
        receivedBytes > limits.maxDownloadBytes || expectedBytes > limits.maxDownloadBytes
    }

    /// What one `didWriteData` callback does, pure: refuse past the cap, or
    /// report a progress value, or nothing (the throttle). `lastReported`
    /// starts at -2 (nothing reported yet).
    enum InFlight: Equatable {
        case refuse(bytes: Int64)
        case report(Double)
        case none
    }

    static func inFlight(written: Int64, expected: Int64, lastReported: Double,
                         limits: UpdateLimits = .standard) -> InFlight {
        if exceedsCap(receivedBytes: written, expectedBytes: expected, limits: limits) {
            return .refuse(bytes: max(written, expected))
        }
        guard expected > 0 else {
            return lastReported == -1 ? .none : .report(-1)
        }
        let fraction = min(1.0, max(0.0, Double(written) / Double(expected)))
        // Whole-percent steps: enough for a bar to move smoothly, few enough
        // that SwiftUI is not asked to redraw for every network packet.
        guard fraction - lastReported >= 0.01 || (fraction >= 1.0 && lastReported < 1.0) else { return .none }
        return .report(fraction)
    }

    /// Keeps the progress a caller sees from ever moving backwards — a retry
    /// starts a fresh attempt whose first fractions may be below where the
    /// last one got to. -1 (size unknown) passes only before any fraction.
    final class HighWater: @unchecked Sendable {
        private let lock = NSLock()
        private var mark: Double = -2
        func admit(_ value: Double) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard value >= mark else { return false }
            mark = value
            return true
        }
    }

    /// The redirect policy, pure: follow a redirect only to an https URL. The
    /// target HOST is deliberately not checked — GitHub moved its asset CDN in
    /// 2025, and TLS plus the signature chain gate the bytes; the strict check
    /// is on the URL we request (`GitHubReleasesAPI.isTrustedAssetURL`).
    public static func followsRedirect(to url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https"
    }

    /// The archive's extension, from the asset's NAME (the URL path is the
    /// server's spelling and may not end in one). Only the two kinds the
    /// updater handles are ever produced.
    public static func fileExtension(forAssetNamed name: String) -> String {
        name.lowercased().hasSuffix(".dmg") ? "dmg" : "zip"
    }

    /// Download `url` to `destination` (replacing anything there). `progress`
    /// is called off the main thread with a fraction in 0...1, throttled to
    /// whole-percent steps, or with -1 once when the size is unknown.
    public static func download(
        from url: URL,
        to destination: URL,
        limits: UpdateLimits = .standard,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var resumeData: Data?
        var attempt = 1
        let highWater = HighWater()
        let forward: @Sendable (Double) -> Void = { value in
            if highWater.admit(value) { progress(value) }
        }
        while true {
            do {
                try await UpdateDownloadSession.run(
                    url: url, resumeData: resumeData, destination: destination,
                    limits: limits, progress: forward)
                return
            } catch {
                guard attempt < maxAttempts, isTransient(error), !Task.isCancelled else { throw error }
                resumeData = (error as? URLError)?.downloadTaskResumeData
                attempt += 1
            }
        }
    }
}

/// One attempt: its own `URLSession` whose delegate is this object, bridged to
/// async with a continuation. A named type so the redirect policy (an
/// https-only refusal) has a place to live.
final class UpdateDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let limits: UpdateLimits
    private let progress: @Sendable (Double) -> Void

    // Guarded by `lock`: touched from the delegate queue and from the
    // cancellation handler.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var refusal: Error?
    private var finishError: Error?
    private var finished = false
    private var cancelled = false

    // Delegate queue only (serial).
    private var lastReported: Double = -2

    private init(destination: URL, limits: UpdateLimits, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.limits = limits
        self.progress = progress
    }

    static func run(
        url: URL,
        resumeData: Data?,
        destination: URL,
        limits: UpdateLimits,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let attempt = UpdateDownloadSession(destination: destination, limits: limits, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Maugham update download"
        let session = URLSession(configuration: .default, delegate: attempt, delegateQueue: queue)
        // The session retains its delegate until invalidated.
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = resumeData.map { session.downloadTask(withResumeData: $0) }
                    ?? session.downloadTask(with: url)
                attempt.lock.lock()
                attempt.continuation = continuation
                attempt.task = task
                // A cancel that arrived before the task existed found nothing
                // to cancel; honour it here, in the same lock, so the
                // download never starts.
                let cancelNow = attempt.cancelled || Task.isCancelled
                attempt.lock.unlock()
                if cancelNow { task.cancel() } else { task.resume() }
            }
        } onCancel: {
            attempt.lock.lock()
            attempt.cancelled = true
            let task = attempt.task
            attempt.lock.unlock()
            task?.cancel()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        switch UpdateDownload.inFlight(written: totalBytesWritten, expected: totalBytesExpectedToWrite,
                                       lastReported: lastReported, limits: limits) {
        case .refuse(let bytes):
            refuse(bytes: bytes, task: downloadTask)
        case .report(let value):
            lastReported = value
            progress(value)
        case .none:
            break
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        if case .report(let value) = UpdateDownload.inFlight(
            written: fileOffset, expected: expectedTotalBytes, lastReported: lastReported, limits: limits) {
            lastReported = value
            progress(value)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `location` is deleted when this method returns: move it now.
        let fm = FileManager.default
        do {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw UpdateDownloadError.badStatus(http.statusCode)
            }
            let size = (try fm.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            if UpdateDownload.exceedsCap(receivedBytes: size, expectedBytes: 0, limits: limits) {
                throw UpdateDownloadError.tooLarge(bytes: size, limit: limits.maxDownloadBytes)
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            lock.lock(); finished = true; lock.unlock()
        } catch {
            lock.lock(); finishError = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let outcome: Error? = refusal ?? finishError ?? error
            ?? (finished ? nil : URLError(.cannotCreateFile))
        lock.unlock()
        if let outcome {
            try? FileManager.default.removeItem(at: destination)
            continuation?.resume(throwing: outcome)
        } else {
            continuation?.resume()
        }
    }

    /// The redirect policy (`UpdateDownload.followsRedirect`): a non-https
    /// target is refused. Answering nil makes the task finish with the 3xx
    /// response itself; the recorded refusal outranks whatever that produces,
    /// so it surfaces as `.insecureRedirect` and the redirect body is never
    /// kept as if it were the archive.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard UpdateDownload.followsRedirect(to: request.url) else {
            lock.lock()
            if refusal == nil { refusal = UpdateDownloadError.insecureRedirect }
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    // MARK: Helpers

    private func refuse(bytes: Int64, task: URLSessionDownloadTask) {
        lock.lock()
        let first = refusal == nil
        if first { refusal = UpdateDownloadError.tooLarge(bytes: bytes, limit: limits.maxDownloadBytes) }
        lock.unlock()
        if first { task.cancel() }
    }
}
