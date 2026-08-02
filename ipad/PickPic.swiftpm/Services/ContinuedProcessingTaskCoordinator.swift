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

    func submit(
        jobID: UUID,
        eventTitle: String,
        operation: ContinuedProcessingOperation,
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
                    task.setTaskCompleted(success: false)
                    return
                }

                let handler: LaunchHandler?

                self?.lock.lock()
                handler = self?.launchHandlers[identifier]
                self?.lock.unlock()

                guard let handler else {
                    continuedTask.setTaskCompleted(
                        success: false
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

        request.strategy = .queue

        try BGTaskScheduler.shared.submit(request)
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
