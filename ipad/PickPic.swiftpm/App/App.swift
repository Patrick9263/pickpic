import Combine
import Network
import SwiftUI
import UIKit

struct AppFeedbackMessage:
    Identifiable,
    Hashable
{
    let id: UUID
    let title: String
    let detail: String
    let systemImage: String

    init(
        title: String,
        detail: String,
        systemImage: String
    ) {
        id = UUID()
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }
}

@MainActor
final class AppFeedbackStore:
    ObservableObject
{
    @Published private(set)
    var message: AppFeedbackMessage?

    private var dismissalTask:
    Task<Void, Never>?

    func show(
        title: String,
        detail: String,
        systemImage: String
    ) {
        dismissalTask?.cancel()

        let newMessage = AppFeedbackMessage(
            title: title,
            detail: detail,
            systemImage: systemImage
        )

        message = newMessage

        dismissalTask = Task {
            do {
                try await Task<Never, Never>
                    .sleep(
                        for: .seconds(5)
                    )
            } catch {
                return
            }

            guard message?.id == newMessage.id else {
                return
            }

            message = nil
        }
    }

    func dismiss() {
        dismissalTask?.cancel()
        dismissalTask = nil
        message = nil
    }
}

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set)
    var isConnected = false

    @Published private(set)
    var revision = 0

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(
        label: "photos.pickpic.app.network-monitor"
    )

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isConnected = path.status == .satisfied

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.isConnected = isConnected
                self.revision += 1
            }
        }

        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

@main
struct PickPicApp: App {
    @StateObject private var configuration =
    APIConfigurationStore()

    @StateObject private var uploadQueue =
    UploadQueueStore()

    @StateObject private var eventFolders =
    EventFolderStore()

    @StateObject private var feedback =
    AppFeedbackStore()

    @StateObject private var networkMonitor =
    NetworkMonitor()

    @State private var previousJobStages:
    [UUID: UploadStage] = [:]

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(configuration)
                .environmentObject(uploadQueue)
                .environmentObject(eventFolders)
                .environmentObject(feedback)
                .task {
                    await uploadQueue
                        .performStorageMaintenance()

                    retryWaitingUploadsIfPossible()
                }
                .onChange(
                    of: networkMonitor.revision
                ) { _, _ in
                    retryWaitingUploadsIfPossible()
                }
                .onChange(
                    of: configuration.revision
                ) { _, _ in
                    retryWaitingUploadsIfPossible()
                }
                .task(id: automaticSyncTaskID) {
                    guard
                        scenePhase == .active,
                        configuration.isConfigured
                    else {
                        return
                    }

                    while !Task.isCancelled {
                        await syncRequestedPhotos()

                        do {
                            try await Task<Never, Never>
                                .sleep(
                                    for: .seconds(30)
                                )
                        } catch {
                            return
                        }
                    }
                }
                .onAppear {
                    previousJobStages = Dictionary(
                        uniqueKeysWithValues:
                            uploadQueue.jobs.map { job in
                                (job.id, job.stage)
                            }
                    )

                    updateIdleTimer(
                        for: uploadQueue.jobs
                    )
                }
                .onReceive(
                    uploadQueue.$jobs
                ) { jobs in
                    updateIdleTimer(
                        for: jobs
                    )

                    handleUploadFeedback(
                        for: jobs
                    )
                }
                .onChange(
                    of: scenePhase
                ) { _, newPhase in
                    switch newPhase {
                    case .active:
                        updateIdleTimer(
                            for: uploadQueue.jobs
                        )
                        retryWaitingUploadsIfPossible()

                    case .inactive,
                            .background:
                        UIApplication.shared
                            .isIdleTimerDisabled = false

                    @unknown default:
                        UIApplication.shared
                            .isIdleTimerDisabled = false
                    }
                }
        }
    }

    @MainActor
    private func retryWaitingUploadsIfPossible() {
        guard
            scenePhase == .active,
            configuration.isConfigured,
            networkMonitor.isConnected
        else {
            return
        }

        Task {
            await uploadQueue
                .resumeWaitingForConnectivityJobs(
                    using: configuration
                )
        }
    }

    private var automaticSyncTaskID: String {
        let latestFolderUpdate =
        eventFolders.references.values
            .map(\.updatedAt.timeIntervalSince1970)
            .max()
        ?? 0

        return [
            String(configuration.revision),
            configuration.isConfigured
            ? "configured"
            : "not-configured",
            scenePhaseKey,
            String(eventFolders.references.count),
            String(latestFolderUpdate)
        ]
        .joined(separator: "|")
    }

    private var scenePhaseKey: String {
        switch scenePhase {
        case .active:
            return "active"

        case .inactive:
            return "inactive"

        case .background:
            return "background"

        @unknown default:
            return "unknown"
        }
    }

    @MainActor
    private func syncRequestedPhotos() async {
        guard configuration.isConfigured else {
            return
        }

        let references =
        eventFolders.references.values
            .sorted { first, second in
                first.updatedAt > second.updatedAt
            }

        guard !references.isEmpty else {
            return
        }

        let client: APIClient

        do {
            client = try configuration.makeClient()
        } catch {
            print(
                "Automatic requested-photo sync could not create the API client:",
                error
            )

            return
        }

        var copiedPhotoCount = 0
        var syncedEventCount = 0

        for reference in references {
            guard !Task.isCancelled else {
                return
            }

            guard FolderBookmarkService
                .canAccessFolder(
                    using: reference.bookmarkData
                )
            else {
                continue
            }

            do {
                if let result = try await RequestedPhotoSyncService
                    .sync(
                        eventID: reference.eventID,
                        reference: reference,
                        using: client
                    ),
                    result.fileResult.copiedPhotoCount > 0
                {
                    copiedPhotoCount +=
                    result.fileResult.copiedPhotoCount
                    syncedEventCount += 1
                }
            } catch {
                print(
                    "Automatic requested-photo sync failed for event \(reference.eventID):",
                    error
                )
            }
        }

        guard copiedPhotoCount > 0 else {
            return
        }

        let eventDescription =
        syncedEventCount == 1
        ? "1 event"
        : "\(syncedEventCount) events"

        let fileDescription =
        copiedPhotoCount == 1
        ? "file"
        : "files"

        feedback.show(
            title: "Liked photos synced",
            detail:
                "Copied \(copiedPhotoCount) RAW \(fileDescription) into To Edit across \(eventDescription).",
            systemImage: "heart.circle.fill"
        )
    }

    @MainActor
    private func handleUploadFeedback(
        for jobs: [UploadJob]
    ) {
        let currentStages = Dictionary(
            uniqueKeysWithValues:
                jobs.map { job in
                    (job.id, job.stage)
                }
        )

        guard !previousJobStages.isEmpty else {
            previousJobStages = currentStages
            return
        }

        for job in jobs {
            guard
                job.stage == .completed,
                previousJobStages[job.id]
                    != .completed
            else {
                continue
            }

            feedback.show(
                title: "Proof upload complete",
                detail:
                    "\(job.eventTitle): \(job.newlyUploadedPhotoCount) uploaded, \(job.duplicatePhotoCount) already existed, and \(job.optimizedPhotoCount) optimized.",
                systemImage: "checkmark.circle.fill"
            )
        }

        previousJobStages = currentStages
    }

    private func updateIdleTimer(
        for jobs: [UploadJob]
    ) {
        let hasActiveProcessing =
        jobs.contains { job in
            switch job.stage {
            case .preparing,
                    .converting,
                    .uploading:
                return true

            case .queued,
                    .prepared,
                    .readyToUpload,
                    .completed,
                    .failed:
                return false
            }
        }

        UIApplication.shared.isIdleTimerDisabled =
        hasActiveProcessing
    }
}
