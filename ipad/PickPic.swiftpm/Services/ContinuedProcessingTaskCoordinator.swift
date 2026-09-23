import BackgroundTasks
import Foundation

enum ContinuedProcessingTaskCoordinatorError:
    LocalizedError
{
    case registrationFailed

    var errorDescription: String? {
        switch self {
        case .registrationFailed:
            return "iPadOS could not register the continued-processing task."
        }
    }
}

final class ContinuedProcessingTaskCoordinator:
    @unchecked Sendable
{
    static let shared =
        ContinuedProcessingTaskCoordinator()

    static let identifierPrefix =
        "photos.pickpic.app.processing"

    static let permittedIdentifier =
        "\(identifierPrefix).*"

    typealias LaunchHandler =
        (BGContinuedProcessingTask) -> Void

    private let lock = NSLock()
    private var registeredIdentifiers: Set<String> = []
    private var launchHandlers:
        [String: LaunchHandler] = [:]

    private init() {}

    func identifier(
        for jobID: UUID
    ) -> String {
        "\(Self.identifierPrefix).\(jobID.uuidString.lowercased())"
    }

    /*
     * Registration stays synchronous and on the caller's thread, exactly as
     * it was before submission went async; only the scheduler round trip in
     * submitRequest(...) moves off the main thread. Register first, then
     * submit, so a launch that iPadOS dispatches before the submission's
     * completion arrives still finds its handler.
     */
    func registerLaunchHandler(
        jobID: UUID,
        launchHandler:
            @escaping LaunchHandler
    ) throws {
        let identifier = identifier(for: jobID)

        let shouldRegister: Bool

        lock.lock()
        launchHandlers[identifier] = launchHandler
        shouldRegister = registeredIdentifiers
            .insert(identifier)
            .inserted
        lock.unlock()

        if shouldRegister {
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: nil
            ) { [weak self] task in
                guard
                    let continuedTask =
                        task as? BGContinuedProcessingTask
                else {
                    // A stale or mismatched scheduler callback has no
                    // PickPic work left to perform. Complete it cleanly so
                    // iPadOS does not retain a failed system task item.
                    task.setTaskCompleted(success: true)
                    return
                }

                let handler: LaunchHandler?

                self?.lock.lock()
                handler = self?.launchHandlers[identifier]
                self?.lock.unlock()

                guard let handler else {
                    // The job was cancelled or reconciled before this
                    // callback arrived. Its durable state already lives in
                    // UploadQueueStore, so dismiss the stale system task.
                    continuedTask.setTaskCompleted(
                        success: true
                    )
                    return
                }

                handler(continuedTask)
            }

            guard registered else {
                lock.lock()
                registeredIdentifiers.remove(identifier)
                launchHandlers.removeValue(
                    forKey: identifier
                )
                lock.unlock()

                throw ContinuedProcessingTaskCoordinatorError
                    .registrationFailed
            }
        }
    }

    /*
     * Submits with the .fail strategy, so the returned result is the whole
     * answer: success means iPadOS is starting the task now, and
     * BGTaskSchedulerErrorCodeImmediateRunIneligible means it will not start
     * it at all. Under the old .queue strategy a request the system could
     * not run immediately was silently queued instead, which is the
     * probable source of the "Waiting to start" item that never went away
     * (#211). A busy system now means foreground processing rather than a
     * queued request -- acceptable because PickPic normally runs in Split
     * View beside Affinity Photo and is not suspended.
     *
     * @concurrent because the SDK header says not to call
     * submitTaskRequest from the main thread, and UploadQueueStore -- the
     * only caller -- is @MainActor. Spelling it out rather than relying on
     * a nonisolated async function's default executor keeps this off the
     * main thread even if the target later adopts approachable
     * concurrency, under which that default would inherit the caller's
     * actor.
     */
    @concurrent
    nonisolated func submitRequest(
        jobID: UUID,
        eventTitle: String,
        operation: ContinuedProcessingOperation
    ) async throws {
        let identifier = identifier(for: jobID)
        let title: String
        let subtitle: String

        switch operation {
        case .prepareConvertAndUpload:
            title = "Preparing \(eventTitle)"
            subtitle = "Waiting to start"

        case .reconvertOnly:
            title = "Rebuilding \(eventTitle)"
            subtitle = "Waiting to start"
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )

        request.strategy = .fail

        try await BGTaskScheduler.shared.submitTaskRequest(
            request
        )
    }

    /*
     * Every submission failure lands on the same foreground fallback; only
     * the explanation differs. ImmediateRunIneligible is the expected
     * busy-system answer under .fail rather than a fault, so it gets its
     * own wording instead of a raw scheduler error description.
     */
    static func foregroundFallbackMessage(
        for error: any Error
    ) -> String {
        if
            let schedulerError =
                error as? BGTaskScheduler.Error,
            schedulerError.code == .immediateRunIneligible
        {
            return "iPadOS could not start background processing right now, so PickPic will continue while the app remains open."
        }

        return "iPadOS background processing was unavailable, so PickPic will continue while the app remains open. \(error.localizedDescription)"
    }

    func cancel(
        jobID: UUID
    ) {
        let identifier = identifier(for: jobID)

        BGTaskScheduler.shared
            .cancel(
                taskRequestWithIdentifier: identifier
            )

        lock.lock()
        launchHandlers.removeValue(
            forKey: identifier
        )
        lock.unlock()
    }
}
