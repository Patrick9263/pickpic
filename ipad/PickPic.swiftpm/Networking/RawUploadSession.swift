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
 * A RAW travels as a resumable multipart upload (#362/#368): one task per
 * missing part, PUT .../raw/parts/:n, all queued at once. The server keeps
 * every part that lands and finishes the upload itself from inside the
 * request that delivers the last one, so iPadOS can run the whole queue with
 * the app suspended or killed and nothing ever needs waking to send the next
 * part or to complete. A drop costs one part, not the file.
 *
 * It is far smaller than BackgroundUploadSession because it needs no on-disk
 * record of transfers that finished while the app was dead. The server is the
 * durable state, twice over: a completed upload has already written
 * photos.raw_storage_key and stamped raw_requests.fulfilled_at, so the next
 * activation sweep sees the photo no longer needs one and skips it; and an
 * interrupted one is described by raw_upload_sessions, so the next sweep
 * calls /raw/start again and is told exactly which parts are still missing.
 * Nothing local has to survive. The one thing a task does carry is its
 * RawPartTaskTag in taskDescription -- state iPadOS keeps for us, used only
 * to redraw progress for transfers that outlive the process.
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

    /*
     * Keyed by taskIdentifier rather than photo id, matching continuations
     * and responseDataByTaskID above -- a photo now has one task per part,
     * and a task outlives any one process's notion of which photo it belongs
     * to (see reattachActiveUploads).
     */
    private var progressHandlersByTaskID:
        [Int: @Sendable (Int64, Int64) -> Void] = [:]

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
        fromFile fileURL: URL,
        tag: RawPartTaskTag,
        onProgress: (@Sendable (Int64, Int64) -> Void)? =
            nil
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation {
            continuation in
            let task = session.uploadTask(
                with: request,
                fromFile: fileURL
            )

            /*
             * Read back by reattachActiveUploads after a relaunch, when this
             * process never called upload() for the task and so has no
             * other record of which photo and part it belongs to.
             */
            task.taskDescription = tag.taskDescription

            lock.lock()
            continuations[task.taskIdentifier] =
                continuation
            responseDataByTaskID[task.taskIdentifier] =
                Data()
            if let onProgress {
                progressHandlersByTaskID[
                    task.taskIdentifier
                ] = onProgress
            }
            lock.unlock()

            task.resume()
        }
    }

    /*
     * Called once per activation, only when hasActiveUploads() has already
     * reported a transfer in flight that this process did not start itself
     * -- i.e. it survived a relaunch. A photo's parts are queued together, so
     * several tasks can belong to it: every still-running task for the first
     * tagged photo found gets a progress handler (told which part it is), and
     * the tag plus the set of part numbers still running is handed back so
     * the caller can re-seed RawDeliveryProgress. A part in the plan with no
     * running task has already finished. Returns nil if everything finished
     * between the two checks, or the task was never tagged as a part (an
     * older build's single-request transfer still in flight).
     */
    func reattachActiveUploads(
        onProgress:
            @escaping @Sendable (
                _ tag: RawPartTaskTag,
                _ sentBytes: Int64
            ) -> Void
    ) async -> (tag: RawPartTaskTag, activeParts: Set<Int>)? {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let tagged = tasks.compactMap {
                    task -> (URLSessionTask, RawPartTaskTag)? in
                    guard
                        task.state != .completed,
                        let description = task.taskDescription,
                        let tag = RawPartTaskTag(
                            taskDescription: description
                        )
                    else {
                        return nil
                    }

                    return (task, tag)
                }

                guard let firstTag = tagged.first?.1 else {
                    continuation.resume(returning: nil)
                    return
                }

                let photoTasks = tagged.filter { _, tag in
                    tag.photoID == firstTag.photoID
                }

                self.lock.lock()
                for (task, tag) in photoTasks {
                    self.progressHandlersByTaskID[
                        task.taskIdentifier
                    ] = { sentBytes, _ in
                        onProgress(tag, sentBytes)
                    }
                }
                self.lock.unlock()

                continuation.resume(
                    returning: (
                        firstTag,
                        Set(photoTasks.map { _, tag in tag.partNumber })
                    )
                )
            }
        }
    }

    /*
     * Stops every part still queued or running for one photo. A part that
     * fails for good (a 401, the storage cap, a session the server no longer
     * has) means the rest of that photo's queue can only fail the same way
     * or land bytes for an upload this sync has abandoned -- and with one
     * connection per host they would hold up the next photo's parts too.
     */
    func cancelUploads(photoID: String) async {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                for task in tasks {
                    guard
                        let description = task.taskDescription,
                        RawPartTaskTag(
                            taskDescription: description
                        )?.photoID == photoID
                    else {
                        continue
                    }

                    task.cancel()
                }

                continuation.resume()
            }
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

    /*
     * The only per-file progress signal the app has (issue #268): these are
     * the largest transfers it makes, one at a time, possibly over
     * cellular, and a static "Uploading..." on a 100 MB file is
     * indistinguishable from a hang.
     */
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        lock.lock()
        let handler =
            progressHandlersByTaskID[task.taskIdentifier]
        lock.unlock()

        guard let handler else {
            return
        }

        DispatchQueue.main.async {
            handler(
                totalBytesSent,
                totalBytesExpectedToSend
            )
        }
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
        progressHandlersByTaskID
            .removeValue(forKey: task.taskIdentifier)
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

/*
 * Which photo and part a background task carries, stored as JSON in its
 * taskDescription. Carries the file's byte size and part size as well, so a
 * relaunched process can rebuild the RawUploadPartPlan -- and so the
 * progress bar -- for a transfer it did not start, without asking the server
 * or re-reading the file.
 */
struct RawPartTaskTag: Codable, Equatable, Sendable {
    let photoID: String
    let partNumber: Int
    let byteSize: Int64
    let partSize: Int64

    init(
        photoID: String,
        partNumber: Int,
        byteSize: Int64,
        partSize: Int64
    ) {
        self.photoID = photoID
        self.partNumber = partNumber
        self.byteSize = byteSize
        self.partSize = partSize
    }

    /*
     * Nil for anything that is not a tag -- in particular the bare photo id
     * an older build wrote for its single-request upload.
     */
    init?(taskDescription: String) {
        guard
            let tag = try? JSONDecoder().decode(
                Self.self,
                from: Data(taskDescription.utf8)
            ),
            tag.partSize > 0,
            tag.plan.size(ofPart: tag.partNumber) != nil
        else {
            return nil
        }

        self = tag
    }

    var taskDescription: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()

        return String(decoding: data, as: UTF8.self)
    }

    var plan: RawUploadPartPlan {
        RawUploadPartPlan(byteSize: byteSize, partSize: partSize)
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
