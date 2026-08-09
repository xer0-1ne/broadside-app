import Foundation
import Observation

/// One file on its way to the server.
struct UploadJob: Identifiable, Sendable {
    enum State: Sendable, Equatable {
        case uploading
        case finished(url: String)
        case failed(message: String)
    }

    let id: UUID
    var filename: String

    /// Zero to one, or nil while the size is still unknown. A photograph picked
    /// from the library reports its size immediately; one still being exported
    /// from iCloud does not.
    var progress: Double?

    var state: State = .uploading
}

/// Sends photographs to the server, and keeps sending them when the app is not
/// on screen.
///
/// This is the reason the app is native. A Broadside author posting a stacked
/// astrophotography frame is uploading several hundred megabytes over a home
/// connection, which takes minutes, and nobody stares at a progress bar for
/// minutes. A foreground transfer is cancelled the moment they switch apps or
/// the screen locks, so the upload that matters most is the one guaranteed to
/// fail.
///
/// A background `URLSession` hands the transfer to the system instead. It
/// continues while the app is suspended, survives the app being terminated, and
/// relaunches the app when it finishes. The costs are real and are why the code
/// below looks the way it does: the body has to be a file on disk rather than
/// data in memory, the session is a process-wide singleton because its
/// identifier must be, and results arrive through a delegate rather than by
/// returning from a function.
@MainActor
@Observable
final class MediaUploader {
    /// One per process. Two sessions sharing an identifier is a runtime error,
    /// and the system reattaches to this one by identifier after a relaunch, so
    /// there is nowhere else for it to live.
    static let shared = MediaUploader()

    static let sessionIdentifier = "io.bytestud.broadside.uploads"

    private(set) var jobs: [UploadJob] = []

    private var session: URLSession!
    private let delegate = UploadDelegate()

    private init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)

        // The system decides when to run these, and left to itself it may wait
        // for the phone to be on wifi and charging. Somebody who has just
        // pressed Upload means now.
        configuration.isDiscretionary = false

        // Wakes the app when a transfer finishes so the post can be updated
        // with the path the server assigned, rather than waiting for the next
        // time somebody opens it.
        configuration.sessionSendsLaunchEvents = true

        // Long, because these are large files on domestic uplinks. This is the
        // gap between bytes moving, not the total, so a slow upload that is
        // still progressing is never cut off.
        configuration.timeoutIntervalForRequest = 120

        // A whole day for the transfer overall. A 2GB frame on a slow
        // connection is a legitimate thing to be doing.
        configuration.timeoutIntervalForResource = 86_400

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "broadside.uploads"

        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)

        delegate.onProgress = { [weak self] id, fraction in
            Task { @MainActor in self?.update(id) { $0.progress = fraction } }
        }
        delegate.onFinished = { [weak self] id, result in
            Task { @MainActor in self?.finish(id, with: result) }
        }

        // After a relaunch the system hands back the transfers that were still
        // running, and without this they would complete into a jobs list that
        // has forgotten they exist.
        Task { await adoptTasksInFlight() }
    }

    // MARK: - Starting an upload

    /// Queues a file and returns the job's identifier so a caller can watch it.
    ///
    /// The file is consumed: the multipart body is written beside it and the
    /// original is left alone, but both are in the temporary directory and both
    /// are cleaned up once the transfer ends.
    @discardableResult
    func upload(
        fileURL: URL,
        filename: String,
        contentType: String,
        using client: BroadsideClient
    ) -> UUID {
        let id = UUID()
        jobs.append(UploadJob(id: id, filename: filename, progress: 0))

        let boundary = "broadside.\(id.uuidString)"

        do {
            let body = try MultipartBody.make(
                fileURL: fileURL,
                filename: filename,
                contentType: contentType,
                boundary: boundary
            )

            let task = session.uploadTask(with: client.uploadRequest(boundary: boundary), fromFile: body)

            // The only way to know which job a delegate callback belongs to
            // after the app has been relaunched. Nothing else survives the
            // process going away.
            task.taskDescription = id.uuidString

            delegate.register(bodyFile: body, for: id)
            task.resume()
        } catch {
            finish(id, with: .failure(APIError.transport(error.localizedDescription)))
        }

        return id
    }

    func job(_ id: UUID) -> UploadJob? {
        jobs.first { $0.id == id }
    }

    /// Forgets a job the caller has dealt with. The list is a work queue, not a
    /// history, so anything already carried into a post should leave it.
    func clear(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        jobs.removeAll {
            if case .uploading = $0.state { return false }
            return true
        }
    }

    // MARK: - Reacting to the delegate

    private func update(_ id: UUID, _ change: (inout UploadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func finish(_ id: UUID, with result: Result<String, Error>) {
        update(id) { job in
            switch result {
            case let .success(url):
                job.progress = 1
                job.state = .finished(url: url)
            case let .failure(error):
                job.state = .failed(message: (error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func adoptTasksInFlight() async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let description = task.taskDescription,
                  let id = UUID(uuidString: description),
                  !jobs.contains(where: { $0.id == id })
            else { continue }

            jobs.append(UploadJob(
                id: id,
                filename: task.originalRequest?.url?.lastPathComponent ?? "Upload",
                progress: task.progress.fractionCompleted
            ))
        }
    }
}

/// The session's delegate.
///
/// Separate from `MediaUploader` because these callbacks arrive on the session's
/// own queue, and the store they feed is main-actor. Everything here does the
/// least possible work and hands the result over.
private final class UploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Both closures are set once during `MediaUploader.init`, before any task
    /// exists to call them, and read only on the serial delegate queue.
    var onProgress: (@Sendable (UUID, Double) -> Void)?
    var onFinished: (@Sendable (UUID, Result<String, Error>) -> Void)?

    private let lock = NSLock()
    private var responses: [UUID: Data] = [:]
    private var bodyFiles: [UUID: URL] = [:]

    func register(bodyFile: URL, for id: UUID) {
        lock.withLock { bodyFiles[id] = bodyFile }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let id = task.jobID else { return }

        // A negative expectation means the size is not known yet, and dividing
        // by it produces a progress bar that runs backwards.
        let fraction = totalBytesExpectedToSend > 0
            ? Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            : 0
        onProgress?(id, min(fraction, 1))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = dataTask.jobID else { return }
        lock.withLock { responses[id, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = task.jobID else { return }

        let (body, bodyFile) = lock.withLock {
            (responses.removeValue(forKey: id) ?? Data(), bodyFiles.removeValue(forKey: id))
        }
        if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) }

        if let error {
            onFinished?(id, .failure(APIError.transport(error.localizedDescription)))
            return
        }

        guard let http = task.response as? HTTPURLResponse else {
            onFinished?(id, .failure(APIError.malformedResponse))
            return
        }

        switch http.statusCode {
        case 200..<300:
            struct Result: Decodable { let url: String }
            if let decoded = try? JSONDecoder().decode(Result.self, from: body) {
                onFinished?(id, .success(decoded.url))
            } else {
                onFinished?(id, .failure(APIError.malformedResponse))
            }
        case 401, 403:
            onFinished?(id, .failure(APIError.unauthorized))
        case 413:
            onFinished?(id, .failure(APIError.tooLarge))
        default:
            struct Envelope: Decodable { let error: String? }
            let message = (try? JSONDecoder().decode(Envelope.self, from: body))?.error ?? ""
            onFinished?(id, .failure(APIError.server(status: http.statusCode, message: message)))
        }
    }
}

private extension URLSessionTask {
    var jobID: UUID? {
        taskDescription.flatMap(UUID.init(uuidString:))
    }
}
