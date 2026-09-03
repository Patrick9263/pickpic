import Foundation

struct BackgroundUploadContext:
    Codable,
    Hashable,
    Sendable
{
    let id: UUID
    let jobID: UUID
    let sourceFilename: String
    let step: UploadOperationStep
    let createdAt: Date

    init(
        id: UUID = UUID(),
        jobID: UUID,
        sourceFilename: String,
        step: UploadOperationStep,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jobID = jobID
        self.sourceFilename = sourceFilename
        self.step = step
        self.createdAt = createdAt
    }
}

struct BackgroundUploadCompletion:
    Codable,
    Hashable,
    Sendable
{
    let context: BackgroundUploadContext
    let statusCode: Int?
    let errorDomain: String?
    let errorCode: Int?
    let errorMessage: String?
    let completedAt: Date

    var succeeded: Bool {
        errorCode == nil
        && statusCode.map { statusCode in
            (200..<300).contains(statusCode)
        } == true
    }

    var shouldRetryWhenConnectivityReturns: Bool {
        guard
            errorDomain == NSURLErrorDomain,
            let errorCode
        else {
            return false
        }

        switch URLError.Code(rawValue: errorCode) {
        case .notConnectedToInternet,
                .networkConnectionLost:
            return true

        default:
            return false
        }
    }
}

final class BackgroundUploadSession:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    static let shared = BackgroundUploadSession()

    static let identifier =
        "photos.pickpic.app.background-proof-uploads"

    private typealias UploadContinuation =
        CheckedContinuation<(Data, URLResponse), Error>

    private let lock = NSLock()

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name =
            "photos.pickpic.app.background-upload-delegate"
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
        [UUID: UploadContinuation] = [:]

    private var connectivityCallbacks:
        [UUID: UploadConnectivityCallbacks] = [:]

    private var waitingContextIDs: Set<UUID> = []
    private var responseDataByTaskID: [Int: Data] = [:]

    private var restoredCompletionHandler:
        (@Sendable (BackgroundUploadCompletion) -> Void)?

    private var backgroundEventsCompletionHandler:
        (() -> Void)?

    private var pendingCompletions:
        [BackgroundUploadCompletion]

    private let pendingCompletionsURL: URL

    override private init() {
        pendingCompletionsURL =
            Self.makePendingCompletionsURL()

        pendingCompletions =
            Self.loadPendingCompletions(
                from: pendingCompletionsURL
            )

        super.init()

        // Recreate the session during launch so iPadOS can reassociate
        // any transfers that outlived the previous app process.
        _ = session
    }

    func upload(
        request: URLRequest,
        fromFile fileURL: URL,
        context: BackgroundUploadContext,
        connectivityCallbacks:
            UploadConnectivityCallbacks?
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation {
            continuation in
            let task = session.uploadTask(
                with: request,
                fromFile: fileURL
            )

            do {
                task.taskDescription =
                    try Self.encode(context: context)
            } catch {
                continuation.resume(throwing: error)
                return
            }

            lock.lock()
            continuations[context.id] = continuation

            if let connectivityCallbacks {
                self.connectivityCallbacks[context.id] =
                    connectivityCallbacks
            }

            responseDataByTaskID[task.taskIdentifier] =
                Data()
            lock.unlock()

            task.resume()
        }
    }

    func activeContexts() async ->
        [BackgroundUploadContext]
    {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let contexts: [BackgroundUploadContext] =
                    tasks.compactMap { task -> BackgroundUploadContext? in
                    guard
                        task.state != .completed,
                        let description = task.taskDescription
                    else {
                        return nil
                    }

                    return try? Self.decode(
                        contextDescription: description
                    )
                }

                continuation.resume(returning: contexts)
            }
        }
    }

    func cancel(contextID: UUID) {
        session.getAllTasks { tasks in
            for task in tasks {
                guard
                    let description = task.taskDescription,
                    let context = try? Self.decode(
                        contextDescription: description
                    ),
                    context.id == contextID
                else {
                    continue
                }

                task.cancel()
            }
        }
    }

    func setRestoredCompletionHandler(
        _ handler:
            @escaping @Sendable (
                BackgroundUploadCompletion
            ) -> Void
    ) {
        let pending: [BackgroundUploadCompletion]

        lock.lock()
        restoredCompletionHandler = handler
        pending = pendingCompletions
        pendingCompletions.removeAll()
        persistPendingCompletionsLocked()
        lock.unlock()

        for completion in pending {
            handler(completion)
        }
    }

    func handleEvents(
        for identifier: String,
        completionHandler:
            @escaping () -> Void
    ) {
        guard identifier == Self.identifier else {
            completionHandler()
            return
        }

        lock.lock()
        backgroundEventsCompletionHandler =
            completionHandler
        lock.unlock()

        _ = session
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
        taskIsWaitingForConnectivity task: URLSessionTask
    ) {
        guard let context = context(for: task) else {
            return
        }

        let callback: (() -> Void)?

        lock.lock()
        let inserted = waitingContextIDs
            .insert(context.id)
            .inserted
        callback = inserted
            ? connectivityCallbacks[context.id]?.onWaiting
            : nil
        lock.unlock()

        callback?()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let context = context(for: task) else {
            return
        }

        let callback: (() -> Void)?

        lock.lock()
        let wasWaiting = waitingContextIDs
            .remove(context.id) != nil
        callback = wasWaiting
            ? connectivityCallbacks[context.id]?.onResumed
            : nil
        lock.unlock()

        callback?()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let context = context(for: task) else {
            return
        }


        let data: Data
        let continuation: UploadContinuation?
        let restoredHandler:
            (@Sendable (BackgroundUploadCompletion) -> Void)?

        lock.lock()
        data = responseDataByTaskID.removeValue(
            forKey: task.taskIdentifier
        ) ?? Data()
        continuation = continuations.removeValue(
            forKey: context.id
        )
        connectivityCallbacks.removeValue(
            forKey: context.id
        )
        waitingContextIDs.remove(context.id)
        restoredHandler = restoredCompletionHandler
        lock.unlock()

        if let continuation {
            if let error {
                continuation.resume(throwing: error)
            } else if let response = task.response {
                continuation.resume(
                    returning: (data, response)
                )
            } else {
                continuation.resume(
                    throwing:
                        BackgroundUploadSessionError
                            .missingResponse
                )
            }

            return
        }

        let nsError = error as NSError?

        /*
         * A non-2xx HTTP response is not a transport error, so `error`
         * is nil and `data` (already buffered by didReceive above) holds
         * the server's real {"error": "..."} body. Preferring it over
         * nsError's description is what lets a relaunch after the app
         * was killed mid-upload show the actual reason -- e.g. the
         * storage-cap message -- instead of a bare status code.
         */
        let serverMessage = try? JSONDecoder()
            .decode(APIErrorResponse.self, from: data)
            .error

        let completion = BackgroundUploadCompletion(
            context: context,
            statusCode:
                (task.response as? HTTPURLResponse)?
                    .statusCode,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            errorMessage:
                serverMessage
                ?? nsError?.localizedDescription,
            completedAt: Date()
        )

        if let restoredHandler {
            restoredHandler(completion)
        } else {
            lock.lock()
            pendingCompletions.append(completion)
            persistPendingCompletionsLocked()
            lock.unlock()
        }
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        let completionHandler: (() -> Void)?

        lock.lock()
        completionHandler =
            backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        lock.unlock()

        guard let completionHandler else {
            return
        }

        DispatchQueue.main.async {
            completionHandler()
        }
    }

    private func context(
        for task: URLSessionTask
    ) -> BackgroundUploadContext? {
        guard let description = task.taskDescription else {
            return nil
        }

        return try? Self.decode(
            contextDescription: description
        )
    }

    private static func encode(
        context: BackgroundUploadContext
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        return try encoder
            .encode(context)
            .base64EncodedString()
    }

    private static func decode(
        contextDescription: String
    ) throws -> BackgroundUploadContext {
        guard let data = Data(
            base64Encoded: contextDescription
        ) else {
            throw BackgroundUploadSessionError
                .invalidTaskDescription
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(
            BackgroundUploadContext.self,
            from: data
        )
    }

    private func persistPendingCompletionsLocked() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(
                pendingCompletions
            )

            try data.write(
                to: pendingCompletionsURL,
                options: [.atomic]
            )
        } catch {
            print(
                "Background upload completion persistence failed:",
                error
            )
        }
    }

    private static func loadPendingCompletions(
        from url: URL
    ) -> [BackgroundUploadCompletion] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return (
            try? decoder.decode(
                [BackgroundUploadCompletion].self,
                from: data
            )
        ) ?? []
    }

    private static func makePendingCompletionsURL()
        -> URL
    {
        let fileManager = FileManager.default
        let rootURL = AppStorageService.rootURL

        try? fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        return rootURL
            .appendingPathComponent(
                "background-upload-completions.json",
                isDirectory: false
            )
    }
}

private enum BackgroundUploadSessionError:
    LocalizedError
{
    case invalidTaskDescription
    case missingResponse

    var errorDescription: String? {
        switch self {
        case .invalidTaskDescription:
            return "PickPic could not identify the background upload."

        case .missingResponse:
            return "The background upload finished without a server response."
        }
    }
}
