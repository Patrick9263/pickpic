import SwiftUI
import UIKit

@main
struct PickPicApp: App {
    @StateObject private var configuration =
    APIConfigurationStore()

    @StateObject private var uploadQueue =
    UploadQueueStore()

    @StateObject private var eventFolders =
    EventFolderStore()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(configuration)
                .environmentObject(uploadQueue)
                .environmentObject(eventFolders)
                .task {
                    await uploadQueue
                        .performStorageMaintenance()
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
                }
                .onChange(
                    of: scenePhase
                ) { _, newPhase in
                    switch newPhase {
                    case .active:
                        updateIdleTimer(
                            for: uploadQueue.jobs
                        )

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
                _ = try await RequestedPhotoSyncService
                    .sync(
                        eventID: reference.eventID,
                        reference: reference,
                        using: client
                    )
            } catch {
                print(
                    "Automatic requested-photo sync failed for event \(reference.eventID):",
                    error
                )
            }
        }
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
