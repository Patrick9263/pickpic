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

/*
 * Holds the outcome of the most recent RawRequestSyncService pass per
 * event. Before this, a missing file or a failed upload only ever reached
 * a print() statement — invisible on a device running detached (#217).
 * LikedPhotosView reads this so a failure stays visible until the next
 * sweep either clears or replaces it, rather than existing only as a line
 * in the Xcode console.
 */
@MainActor
final class RawRequestStatusStore: ObservableObject {
    struct Failure: Equatable {
        let missingFilenames: [String]
        let failedFilenames: [String]
        let checkedAt: Date
    }

    @Published private(set)
    var failuresByEventID: [String: Failure] = [:]

    func record(
        eventID: String,
        missingFilenames: [String],
        failedFilenames: [String]
    ) {
        guard !missingFilenames.isEmpty || !failedFilenames.isEmpty else {
            failuresByEventID[eventID] = nil
            return
        }

        failuresByEventID[eventID] = Failure(
            missingFilenames: missingFilenames,
            failedFilenames: failedFilenames,
            checkedAt: Date()
        )
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

@MainActor
final class PickPicAppDelegate:
    NSObject,
    UIApplicationDelegate
{
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession
            identifier: String,
        completionHandler:
            @escaping () -> Void
    ) {
        /*
         * RAW deliveries run on their own background session (see
         * RawUploadSession), so the relaunch events arrive under a second
         * identifier. It claims the handler if the identifier is its own.
         */
        guard
            !RawUploadSession.shared.handleEvents(
                for: identifier,
                completionHandler: completionHandler
            )
        else {
            return
        }

        BackgroundUploadSession.shared.handleEvents(
            for: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct PickPicApp: App {
    @UIApplicationDelegateAdaptor(PickPicAppDelegate.self)
    private var appDelegate

    @StateObject private var configuration =
    APIConfigurationStore()

    @StateObject private var uploadQueue =
    UploadQueueStore()

    @StateObject private var eventFolders =
    EventFolderStore()

    @StateObject private var feedback =
    AppFeedbackStore()

    @StateObject private var rawRequestStatus =
    RawRequestStatusStore()

    @StateObject private var networkMonitor =
    NetworkMonitor()

    @StateObject private var finishedEdits =
    FinishedEditsWatcher()

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
                .environmentObject(finishedEdits)
                .environmentObject(rawRequestStatus)
                /*
                 * Delivers the applinks:app.pickpic.photos universal link
                 * (entitlement + the AASA route the worker serves at
                 * /.well-known/apple-app-site-association) for both a cold
                 * launch and a tap while the app is already running --
                 * SwiftUI's onOpenURL covers both, so there is no separate
                 * .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) path
                 * to keep in sync with it.
                 */
                .onOpenURL { url in
                    Task {
                        await handleIncomingSignInLink(url)
                    }
                }
                .task {
                    BackgroundUploadSession.shared
                        .setRestoredCompletionHandler { completion in
                            Task { @MainActor in
                                await uploadQueue
                                    .handleRestoredBackgroundUploadCompletion(
                                        completion,
                                        using: configuration,
                                        resumeIfActive:
                                            UIApplication.shared
                                                .applicationState
                                                == .active
                                    )
                            }
                        }

                    await uploadQueue
                        .reconcileBackgroundTransfers(
                            using: configuration,
                            resumeIfActive:
                                scenePhase == .active
                        )

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

                        /*
                         * The watcher's interval does not advance while
                         * iPadOS has the app suspended, so an edit saved
                         * in Affinity would otherwise wait out whatever
                         * was left of it before anything noticed.
                         */
                        finishedEdits.scanNow()

                        /*
                         * Re-running this (not just at cold launch) lets a
                         * later successful pass clear storageErrorMessage
                         * if an earlier one failed — otherwise that banner
                         * is stuck for the rest of the app session (#132).
                         */
                        Task {
                            await uploadQueue
                                .performStorageMaintenance()
                        }

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

    /*
     * The token extraction and redemption here is exactly
     * AuthClient.signIn(withPastedLink:) -- a universal link and a pasted
     * link both end up as the same "https://app.pickpic.photos/sign-in?
     * token=..." string, so there is no separate parsing path to keep in
     * sync with ConnectionSettingsView's paste flow. Errors (an already-used
     * token, an expired one, connectivity) surface as a feedback toast
     * rather than a sheet, because unlike the paste flow there is no
     * ConnectionSettingsView on screen to show them in -- the tap can land
     * from anywhere in the app, or before it has launched at all.
     */
    @MainActor
    private func handleIncomingSignInLink(_ url: URL) async {
        do {
            let credential = try await configuration
                .makeAuthClient()
                .signIn(withPastedLink: url.absoluteString)

            try configuration.save(credential)

            feedback.show(
                title: "Signed in",
                detail:
                    credential.accountName.map { "Signed in to \($0)." }
                    ?? "This iPad is now signed in to PickPic.",
                systemImage: "checkmark.circle.fill"
            )
        } catch {
            feedback.show(
                title: "Sign-in link didn't work",
                detail: error.localizedDescription,
                systemImage: "exclamationmark.triangle.fill"
            )
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
                .resumeBackgroundReconciliationJobs(
                    using: configuration
                )

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

    /*
     * EventFolderStore never drops a reference except on explicit removal,
     * so it accumulates one entry per event the photographer has ever
     * pointed the app at. Sweeping all of them every 30 seconds -- for as
     * long as the app is open, which in Split View beside Affinity is most
     * of the day -- means a full photo-list fetch per stale event,
     * indefinitely (#235).
     *
     * updatedAt only moves when there is a reason to believe the event is
     * still live on this device: a new upload job, or the operator picking
     * the To Edit / finals destination folder. Viewers keep hearting and
     * requesting RAWs for a gallery for a while after the photographer's
     * own activity stops, so the window here is generous rather than tight.
     */
    private static let requestedPhotoSyncWindow: TimeInterval =
    14 * 24 * 60 * 60

    @MainActor
    private func syncRequestedPhotos() async {
        guard configuration.isConfigured else {
            return
        }

        let cutoff =
        Date().addingTimeInterval(
            -Self.requestedPhotoSyncWindow
        )

        let references =
        eventFolders.references.values
            .filter { reference in
                reference.updatedAt >= cutoff
            }
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

        var movedPhotoCount = 0
        var syncedEventCount = 0
        var uploadedRawCount = 0
        var uploadedRawBytes: Int64 = 0

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
                let result = try await RequestedPhotoSyncService
                    .sync(
                        eventID: reference.eventID,
                        reference: reference,
                        using: client
                    )

                if
                    let result,
                    result.fileResult.movedPhotoCount > 0
                {
                    movedPhotoCount +=
                    result.fileResult.movedPhotoCount
                    syncedEventCount += 1
                }

                for filename in result?.fileResult.failedFilenames ?? [] {
                    print(
                        "To Edit sync could not copy \(filename) in event \(reference.eventID)."
                    )
                }

                /*
                 * Handed the photos the pass above already fetched, so
                 * delivering RAWs costs no second round trip per event.
                 * Nil means that pass was skipped (another sync of the
                 * same event was already running), in which case this one
                 * fetches for itself rather than sitting the sweep out.
                 */
                if let rawResult = try await RawRequestSyncService
                    .sync(
                        eventID: reference.eventID,
                        reference: reference,
                        using: client,
                        photos: result?.photos
                    )
                {
                    uploadedRawCount +=
                    rawResult.uploadedPhotoCount

                    uploadedRawBytes +=
                    rawResult.uploadedByteCount

                    for filename in rawResult.failures {
                        print(
                            "RAW delivery failed for \(filename) in event \(reference.eventID)."
                        )
                    }

                    for filename in rawResult.missingFilenames {
                        print(
                            "RAW delivery could not find \(filename) in event \(reference.eventID)."
                        )
                    }

                    rawRequestStatus.record(
                        eventID: reference.eventID,
                        missingFilenames: rawResult.missingFilenames,
                        failedFilenames: rawResult.failures
                    )
                }
            } catch APIClientError.server(404, _) {
                /*
                 * The server does not know this event. That is normal
                 * rather than a failure: an event created offline only
                 * gets registered when its first upload runs, and an
                 * event deleted from the dashboard leaves its folder
                 * reference behind on the device. Either way there are
                 * no requested photos to move, and this sweep runs on
                 * every activation — so logging it would repeat
                 * forever. The liked-photos screen still reports the
                 * 404, because there the photographer asked.
                 */
                continue
            } catch {
                print(
                    "Automatic requested-photo sync failed for event \(reference.eventID):",
                    error
                )
            }
        }

        /*
         * Reported separately from the To Edit sync above, because they are
         * different events to the photographer: one moved files around on
         * the iPad, the other sent originals off it.
         */
        if uploadedRawCount > 0 {
            let rawFileDescription =
            uploadedRawCount == 1
            ? "RAW file"
            : "RAW files"

            let formattedBytes =
            ByteCountFormatter.string(
                fromByteCount: uploadedRawBytes,
                countStyle: .file
            )

            feedback.show(
                title: "Requested RAWs delivered",
                detail:
                    "Sent \(uploadedRawCount) \(rawFileDescription) (\(formattedBytes)) to viewers who asked for them.",
                systemImage: "arrow.up.doc.fill"
            )
        }

        guard movedPhotoCount > 0 else {
            return
        }

        let eventDescription =
        syncedEventCount == 1
        ? "1 event"
        : "\(syncedEventCount) events"

        let fileDescription =
        movedPhotoCount == 1
        ? "file"
        : "files"

        feedback.show(
            title: "Liked photos synced",
            detail:
                "Moved \(movedPhotoCount) RAW \(fileDescription) into To Edit across \(eventDescription).",
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
                title: completionTitle(for: job),
                detail: completionDetail(for: job),
                systemImage: "checkmark.circle.fill"
            )
        }

        previousJobStages = currentStages
    }

    /*
     * A job that uploaded nothing is still a success: it means the event
     * already had every photo. Saying "0 uploaded" for that reads like a
     * failure, so it gets its own wording.
     */
    private func completionTitle(
        for job: UploadJob
    ) -> String {
        job.newlyUploadedPhotoCount == 0
            && job.alreadyExistedPhotoCount > 0
        ? "Nothing left to upload"
        : "Proof upload complete"
    }

    private func completionDetail(
        for job: UploadJob
    ) -> String {
        let existing = job.alreadyExistedPhotoCount
        let uploaded = job.newlyUploadedPhotoCount

        if uploaded == 0, existing > 0 {
            let photoDescription =
            existing == 1
            ? "photo was"
            : "photos were"

            return "\(job.eventTitle): all \(existing) \(photoDescription) already uploaded, so nothing was converted."
        }

        return "\(job.eventTitle): \(uploaded) uploaded, \(existing) already existed, and \(job.optimizedPhotoCount) optimized."
    }

    private func updateIdleTimer(
        for jobs: [UploadJob]
    ) {
        let hasActiveProcessing =
        jobs.contains { job in
            switch job.stage {
            case .preparing,
                    .preflighting,
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
