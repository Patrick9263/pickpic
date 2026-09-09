import Foundation

/*
 * The background URLSession that carries an original RAW to the server when a
 * gallery viewer has asked for one (issue #205).
 *
 * Deliberately its own session rather than a second kind of transfer on
 * BackgroundUploadSession. That class's BackgroundUploadContext carries a
 * required jobID, and UploadQueueStore's restored-completion handler drives
 * updateJob(context.jobID) off it — a RAW upload belongs to no UploadJob, so
 * sharing the session would mean smuggling a synthetic id past a lookup that
 * can never resolve it. Keeping them apart also means no UploadStage or
 * UploadOperationStep case is added, and so none of the hand-rolled
 * "is this job busy" chains in UploadQueueStore need revisiting.
 *
 * It is far smaller than BackgroundUploadSession because it needs no on-disk
 * record of transfers that finished while the app was dead. The server is the
 * durable state: a completed upload has already written photos.raw_storage_key
 * and stamped raw_requests.fulfilled_at, so the next activation sweep sees the
 * photo no longer needs one and skips it. An interrupted upload leaves
 * fulfilled_at null and is simply retried. Nothing local has to survive.
 */
final class RawUploadSession:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    static let shared = RawUploadSession()

    static let identifier =
        "photos.pickpic.app.background-raw-uploads"

    private typealias UploadContinuation =
        CheckedContinuation<(Data, URLResponse), Error>

    private let lock = NSLock()

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name =
            "photos.pickpic.app.raw-upload-delegate"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private lazy var session: URLSession = {
        let configuration =
            URLSessionConfiguration.background(
                withIdentifier: Self.identifier
            )

        configuration.waitsForConnectivity = true
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true

        /*
         * One at a time. These are the largest transfers the app makes, and
         * running several in parallel only shares the same connection out
         * while making each one slower to finish.
         */
        configuration.httpMaximumConnectionsPerHost = 1

        configuration.timeoutIntervalForResource =
            7 * 24 * 60 * 60

        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
    }()

    private var continuations:
        [Int: UploadContinuation] = [:]

    private var responseDataByTaskID: [Int: Data] = [:]

    private var backgroundEventsCompletionHandler:
        (() -> Void)?

    override private init() {
        super.init()

        /*
         * Recreated at launch so iPadOS can reassociate any RAW transfer
         * that outlived the previous process, the same way
         * BackgroundUploadSession does.
         */
        _ = session
    }

    func upload(
        request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation {
            continuation in
            let task = session.uploadTask(
                with: request,
                fromFile: fileURL
            )

            lock.lock()
            continuations[task.taskIdentifier] =
                continuation
            responseDataByTaskID[task.taskIdentifier] =
                Data()
            lock.unlock()

            task.resume()
        }
    }

    /*
     * Whether a transfer this session started is still running. The sweep
     * checks it before staging anything, so a relaunch that lands while an
     * upload is mid-flight does not start the same one a second time.
     */
    func hasActiveUploads() async -> Bool {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(
                    returning: tasks.contains { task in
                        task.state != .completed
                    }
                )
            }
        }
    }

    func handleEvents(
        for identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard identifier == Self.identifier else {
            return false
        }

        lock.lock()
        backgroundEventsCompletionHandler =
            completionHandler
        lock.unlock()

        _ = session

        return true
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        responseDataByTaskID[
            dataTask.taskIdentifier,
            default: Data()
        ].append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let continuation =
            continuations
            .removeValue(forKey: task.taskIdentifier)
        let data =
            responseDataByTaskID
            .removeValue(forKey: task.taskIdentifier)
            ?? Data()
        lock.unlock()

        /*
         * No continuation means the transfer finished after the process that
         * started it had gone. There is nothing to resume and nothing to
         * record: the server already knows the outcome, and the next sweep
         * reads it from there.
         */
        guard let continuation else {
            return
        }

        if let error {
            continuation.resume(throwing: error)
            return
        }

        guard let response = task.response else {
            continuation.resume(
                throwing: RawUploadSessionError
                    .missingResponse
            )

            return
        }

        continuation.resume(
            returning: (data, response)
        )
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        lock.lock()
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        lock.unlock()

        guard let handler else {
            return
        }

        DispatchQueue.main.async {
            handler()
        }
    }
}

private enum RawUploadSessionError: LocalizedError {
    case missingResponse

    var errorDescription: String? {
        switch self {
        case .missingResponse:
            return """
            The RAW upload ended before PickPic received a \
            server response.
            """
        }
    }
}
