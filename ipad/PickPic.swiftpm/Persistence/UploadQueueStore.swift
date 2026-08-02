import BackgroundTasks
import Combine
import Foundation

private enum UploadQueuePipelineError:
    LocalizedError
{
    case variantGenerationFailed(
        filename: String,
        reason: String
    )

    case variantUploadFailed(
        filename: String,
        reason: String,
        isNetworkRelated: Bool,
        retryWhenConnectivityReturns: Bool
    )

    var errorDescription: String? {
        switch self {
        case let .variantGenerationFailed(
            filename,
            reason
        ):
            return """
            \(filename) uploaded, but PickPic could not create its \
            thumbnail and preview. Retry this photo without \
            duplicating the full upload. \(reason)
            """

        case let .variantUploadFailed(
            filename,
            reason,
            _,
            _
        ):
            return """
            \(filename) uploaded, but its thumbnail and preview could \
            not be uploaded. Retry this photo without duplicating the \
            full upload. \(reason)
            """
        }
    }
}

private struct RelinkedUploadFolder: Sendable {
    let name: String
    let bookmarkData: Data
}

private struct ActiveContinuedProcessingTask {
    let backgroundTask: BGContinuedProcessingTask
    let operationTask: Task<Void, Never>
}

private enum UploadFolderRelinkError: LocalizedError, Sendable {
    case jobNotFound
    case operationInProgress
    case folderAccessDenied
    case selectedItemIsNotFolder
    case missingSourceFiles([String])
    case mismatchedSourceFiles([String])

    var errorDescription: String? {
        switch self {
        case .jobNotFound:
            return "The saved upload could not be found."

        case .operationInProgress:
            return "Wait for the current upload operation to finish before changing its folder."

        case .folderAccessDenied:
            return "PickPic could not access the selected folder."

        case .selectedItemIsNotFolder:
            return "The selected item is not a folder."

        case let .missingSourceFiles(filenames):
            let preview = filenames.prefix(5).joined(separator: ", ")
            let remainingCount = max(filenames.count - 5, 0)
            let suffix = remainingCount > 0
                ? " and \(remainingCount) more"
                : ""

            return "The selected folder does not contain the original source files needed by this upload: \(preview)\(suffix)."

        case let .mismatchedSourceFiles(filenames):
            let preview = filenames.prefix(5).joined(separator: ", ")
            let remainingCount = max(filenames.count - 5, 0)
            let suffix = remainingCount > 0
                ? " and \(remainingCount) more"
                : ""

            return "The selected folder contains files with the expected names but different sizes: \(preview)\(suffix). Select the original event folder."
        }
    }
}

@MainActor
final class UploadQueueStore: ObservableObject {
    @Published private(set)
    var jobs: [UploadJob] = []

    @Published private(set)
    var loadErrorMessage: String?

    @Published private(set)
    var storageCleanupMessage: String?

    @Published private(set)
    var storageErrorMessage: String?

    @Published private(set)
    var recoveryMessage: String?

    private let storageURL: URL
    private var runningPipelineJobIDs: Set<UUID> = []
    private var pauseRequestedJobIDs: Set<UUID> = []
    private var activeConnectivityOperationIDs: [UUID: UUID] = [:]
    private var isResumingWaitingForConnectivityJobs = false
    private var activeContinuedProcessingTasks:
        [UUID: ActiveContinuedProcessingTask] = [:]

    @Published private(set)
    var retryingEventIDs: Set<String> = []

    init() {
        storageURL = Self.makeStorageURL()
        load()
    }

    func performStorageMaintenance() async {
        let jobsSnapshot = jobs

        do {
            let result = try await Task.detached(
                priority: .utility
            ) {
                try AppStorageService.cleanup(
                    jobs: jobsSnapshot
                )
            }
                .value

            storageErrorMessage = nil

            guard
                result.removedItemCount > 0
            else {
                storageCleanupMessage = nil
                return
            }

            let reclaimedSize =
            ByteCountFormatter.string(
                fromByteCount:
                    result.reclaimedBytes,
                countStyle: .file
            )

            storageCleanupMessage =
            """
            PickPic recovered \(reclaimedSize) of \
            temporary storage.
            """
        } catch {
            storageCleanupMessage = nil

            storageErrorMessage =
            """
            Temporary storage could not be cleaned: \
            \(error.localizedDescription)
            """
        }
    }

    func jobs(
        for eventID: String
    ) -> [UploadJob] {
        jobs.filter { job in
            job.eventID == eventID
        }
    }

    func completedJobCount(
        for eventID: String
    ) -> Int {
        jobs.filter { job in
            job.eventID == eventID
            && job.stage == .completed
        }
        .count
    }

    func isRetryingIncompleteJobs(
        for eventID: String
    ) -> Bool {
        retryingEventIDs.contains(eventID)
    }

    func requestPause(
        jobID: UUID
    ) {
        guard
            let job = jobs.first(
                where: { job in
                    job.id == jobID
                }
            ),
            job.stage == .uploading
        else {
            return
        }

        pauseRequestedJobIDs.insert(jobID)

        do {
            try updateJob(jobID) { job in
                job.uploadProgress.pauseRequested = true
                job.updatedAt = Date()
            }
        } catch {
            loadErrorMessage =
            """
            PickPic could not save the pause request: \
            \(error.localizedDescription)
            """
        }
    }

    func startUserInitiatedUploadPipeline(
        jobID: UUID,
        using configuration: APIConfigurationStore
    ) {
        guard
            let job = jobs.first(
                where: { job in
                    job.id == jobID
                }
            )
        else {
            return
        }

        if job.stage == .readyToUpload {
            Task {
                await runUploadPipeline(
                    jobID: jobID,
                    using: configuration
                )
            }
            return
        }

        guard
            job.stage == .queued
                || job.stage == .failed
                || job.stage == .prepared
        else {
            return
        }

        submitContinuedProcessing(
            job: job,
            operation: .prepareConvertAndUpload,
            configuration: configuration
        )
    }

    func startUserInitiatedReconversion(
        jobID: UUID
    ) {
        guard
            let job = jobs.first(
                where: { job in
                    job.id == jobID
                }
            ),
            job.stage == .prepared
                || job.stage == .readyToUpload
        else {
            return
        }

        submitContinuedProcessing(
            job: job,
            operation: .reconvertOnly,
            configuration: nil
        )
    }

    private func submitContinuedProcessing(
        job: UploadJob,
        operation: ContinuedProcessingOperation,
        configuration: APIConfigurationStore?
    ) {
        guard
            job.continuedProcessing?
                .isScheduledOrActive != true
        else {
            return
        }

        let coordinator =
            ContinuedProcessingTaskCoordinator.shared
        let identifier = coordinator.identifier(
            for: job.id
        )
        let requestedAt = Date()

        do {
            try updateJob(job.id) { job in
                job.continuedProcessing =
                    ContinuedProcessingState(
                        identifier: identifier,
                        operation: operation,
                        requestedAt: requestedAt,
                        status: .scheduled,
                        startedAt: nil,
                        endedAt: nil,
                        message:
                            "Waiting for iPadOS to start background processing."
                    )
                job.updatedAt = requestedAt
            }
        } catch {
            loadErrorMessage =
                "PickPic could not save the background-processing request: \(error.localizedDescription)"
            return
        }

        do {
            try coordinator.submit(
                jobID: job.id,
                eventTitle: job.eventTitle,
                operation: operation
            ) { [weak self, weak configuration] task in
                Task { @MainActor [weak self, weak configuration] in
                    self?.handleContinuedProcessingTask(
                        task,
                        jobID: job.id,
                        operation: operation,
                        configuration: configuration
                    )
                }
            }
        } catch {
            let fallbackMessage =
                "iPadOS background processing was unavailable, so PickPic will continue while the app remains open. \(error.localizedDescription)"

            do {
                try updateJob(job.id) { job in
                    guard
                        job.continuedProcessing?
                            .identifier == identifier
                    else {
                        return
                    }

                    job.continuedProcessing?.status =
                        .foregroundFallback
                    job.continuedProcessing?.message =
                        fallbackMessage
                    job.updatedAt = Date()
                }
            } catch {
                loadErrorMessage =
                    "PickPic could not save the foreground fallback state: \(error.localizedDescription)"
            }

            Task { @MainActor [weak self, weak configuration] in
                guard let self else {
                    return
                }

                let preparationSucceeded: Bool

                switch operation {
                case .prepareConvertAndUpload:
                    preparationSucceeded = await self
                        .runPreparationAndConversionPipeline(
                            jobID: job.id
                        )

                case .reconvertOnly:
                    preparationSucceeded = await self
                        .runReconversionPipeline(
                            jobID: job.id
                        )
                }

                self.clearContinuedProcessingState(
                    jobID: job.id,
                    identifier: identifier
                )

                if
                    preparationSucceeded,
                    operation == .prepareConvertAndUpload,
                    let configuration
                {
                    await self.runUploadPipeline(
                        jobID: job.id,
                        using: configuration
                    )
                }
            }
        }
    }

    private func handleContinuedProcessingTask(
        _ backgroundTask: BGContinuedProcessingTask,
        jobID: UUID,
        operation: ContinuedProcessingOperation,
        configuration: APIConfigurationStore?
    ) {
        let expectedIdentifier =
            ContinuedProcessingTaskCoordinator
                .shared
                .identifier(for: jobID)

        guard
            let currentJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            ),
            currentJob.continuedProcessing?
                .identifier == expectedIdentifier,
            currentJob.continuedProcessing?
                .operation == operation
        else {
            backgroundTask.setTaskCompleted(
                success: false
            )
            return
        }

        let startedAt = Date()

        do {
            try updateJob(jobID) { job in
                guard
                    job.continuedProcessing?
                        .operation == operation
                else {
                    return
                }

                job.continuedProcessing?.status = .active
                job.continuedProcessing?.startedAt =
                    startedAt
                job.continuedProcessing?.message =
                    "iPadOS background processing is active. You can switch apps or lock the iPad."
                job.updatedAt = startedAt
            }
        } catch {
            loadErrorMessage =
                "PickPic could not save the active background-processing state: \(error.localizedDescription)"
        }

        if let job = jobs.first(
            where: { job in
                job.id == jobID
            }
        ) {
            updateContinuedProcessingProgress(
                for: job,
                task: backgroundTask,
                completedUnitOverride:
                    operation == .reconvertOnly
                    ? 0
                    : nil
            )
        }

        let operationTask = Task { @MainActor [weak self, weak configuration] in
            await Task.yield()

            guard let self else {
                backgroundTask.setTaskCompleted(
                    success: false
                )
                return
            }

            let succeeded: Bool

            switch operation {
            case .prepareConvertAndUpload:
                succeeded = await self
                    .runPreparationAndConversionPipeline(
                        jobID: jobID
                    )

            case .reconvertOnly:
                succeeded = await self
                    .runReconversionPipeline(
                        jobID: jobID
                    )
            }

            let wasCancelled = Task.isCancelled

            if wasCancelled {
                self.markContinuedProcessingDeferred(
                    jobID: jobID,
                    message:
                        "Background processing stopped before the batch finished. Saved JPEGs were preserved; tap Continue to resume."
                )
            } else {
                self.clearContinuedProcessingState(
                    jobID: jobID,
                    identifier: expectedIdentifier
                )
            }

            if
                succeeded,
                !wasCancelled,
                operation == .prepareConvertAndUpload,
                let configuration
            {
                Task { @MainActor [weak self, weak configuration] in
                    guard
                        let self,
                        let configuration
                    else {
                        return
                    }

                    await self.runUploadPipeline(
                        jobID: jobID,
                        using: configuration
                    )
                }

                // Give the upload pipeline an opportunity to enqueue
                // its first file-backed background URLSession task
                // before this CPU-processing grant is completed.
                await Task.yield()
            }

            self.activeContinuedProcessingTasks
                .removeValue(forKey: jobID)

            backgroundTask.setTaskCompleted(
                success: succeeded && !wasCancelled
            )
        }

        activeContinuedProcessingTasks[jobID] =
            ActiveContinuedProcessingTask(
                backgroundTask: backgroundTask,
                operationTask: operationTask
            )

        backgroundTask.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.expireContinuedProcessing(
                    jobID: jobID
                )
            }
        }
    }

    private func expireContinuedProcessing(
        jobID: UUID
    ) {
        guard
            let activeTask =
                activeContinuedProcessingTasks[jobID]
        else {
            return
        }

        activeTask.operationTask.cancel()

        markContinuedProcessingDeferred(
            jobID: jobID,
            message:
                "iPadOS deferred this background task. PickPic preserved completed conversions and can resume from the next missing photo."
        )
    }

    private func markContinuedProcessingDeferred(
        jobID: UUID,
        message: String
    ) {
        do {
            try updateJob(jobID) { job in
                guard
                    job.continuedProcessing != nil
                else {
                    return
                }

                job.continuedProcessing?.status = .deferred
                job.continuedProcessing?.endedAt = Date()
                job.continuedProcessing?.message = message
                job.updatedAt = Date()
            }
        } catch {
            loadErrorMessage =
                "PickPic could not save the deferred background-processing state: \(error.localizedDescription)"
        }
    }

    private func clearContinuedProcessingState(
        jobID: UUID,
        identifier: String
    ) {
        do {
            try updateJob(jobID) { job in
                guard
                    job.continuedProcessing?
                        .identifier == identifier
                else {
                    return
                }

                job.continuedProcessing = nil
                job.updatedAt = Date()
            }
        } catch {
            loadErrorMessage =
                "PickPic could not clear the background-processing state: \(error.localizedDescription)"
        }
    }

    func retryIncompleteJobs(
        for eventID: String,
        using configuration: APIConfigurationStore
    ) async {
        guard !retryingEventIDs.contains(eventID) else {
            return
        }

        retryingEventIDs.insert(eventID)

        defer {
            retryingEventIDs.remove(eventID)
        }

        let jobIDs = jobs
            .filter { job in
                job.eventID == eventID
                && job.stage != .completed
                && job.stage != .preparing
                && job.stage != .converting
                && job.stage != .uploading
            }
            .sorted { first, second in
                first.createdAt < second.createdAt
            }
            .map(\.id)

        for jobID in jobIDs {
            guard !Task.isCancelled else {
                return
            }

            await runUploadPipeline(
                jobID: jobID,
                using: configuration
            )

            guard
                let refreshedJob = jobs.first(
                    where: { job in
                        job.id == jobID
                    }
                )
            else {
                continue
            }

            if refreshedJob.uploadProgress.isPaused {
                return
            }

            if refreshedJob.uploadProgress
                .lastFailure?
                .isNetworkRelated == true
            {
                return
            }
        }
    }

    func resumeWaitingForConnectivityJobs(
        using configuration: APIConfigurationStore
    ) async {
        guard !isResumingWaitingForConnectivityJobs else {
            return
        }

        isResumingWaitingForConnectivityJobs = true

        defer {
            isResumingWaitingForConnectivityJobs = false
        }

        let jobIDs = jobs
            .filter { job in
                job.stage == .readyToUpload
                && job.uploadProgress
                    .isWaitingForConnectivity
            }
            .sorted { first, second in
                first.createdAt < second.createdAt
            }
            .map(\.id)

        for jobID in jobIDs {
            guard !Task.isCancelled else {
                return
            }

            await runUploadPipeline(
                jobID: jobID,
                using: configuration
            )

            guard
                let refreshedJob = jobs.first(
                    where: { job in
                        job.id == jobID
                    }
                )
            else {
                continue
            }

            if refreshedJob.uploadProgress
                .isWaitingForConnectivity
                || refreshedJob.uploadProgress.isPaused
            {
                return
            }
        }
    }

    func reconcileBackgroundTransfers(
        using configuration: APIConfigurationStore,
        resumeIfActive: Bool
    ) async {
        let activeContexts = await BackgroundUploadSession
            .shared
            .activeContexts()

        let activeContextsByID = Dictionary(
            uniqueKeysWithValues:
                activeContexts.map { context in
                    (context.id, context)
                }
        )

        let savedTransfers = jobs.compactMap { job in
            job.uploadProgress.activeBackgroundTransfer
                .map { context in
                    (job.id, context)
                }
        }

        var jobIDsToResume: [UUID] = []

        for (jobID, context) in savedTransfers {
            guard
                jobs.first(where: { job in
                    job.id == jobID
                })?
                .uploadProgress
                .activeBackgroundTransfer?
                .id == context.id
            else {
                continue
            }

            if let activeContext =
                activeContextsByID[context.id]
            {
                do {
                    try updateJob(jobID) { job in
                        job.stage = .uploading
                        job.uploadProgress
                            .activeBackgroundTransfer =
                                activeContext
                        job.uploadProgress.currentFilename =
                            activeContext.sourceFilename
                        job.uploadProgress.currentStep =
                            activeContext.step
                        job.uploadProgress
                            .backgroundTransferNeedsReconciliation =
                                false

                        if !job.uploadProgress
                            .isWaitingForConnectivity
                        {
                            job.uploadProgress.errorMessage =
                                "Uploading with iPadOS in the background. You can lock the iPad or switch apps."
                        }

                        job.uploadProgress.currentRunStartedAt = nil
                        job.updatedAt = Date()
                    }
                } catch {
                    loadErrorMessage =
                        "PickPic could not restore the background upload state: \(error.localizedDescription)"
                }

                if jobs.first(where: { job in
                    job.id == jobID
                })?.uploadProgress.isPauseRequested == true
                {
                    pauseRequestedJobIDs.insert(jobID)
                }

                continue
            }

            let shouldRemainPaused =
                jobs.first(where: { job in
                    job.id == jobID
                })?.uploadProgress.isPauseRequested == true

            do {
                try updateJob(jobID) { job in
                    guard
                        job.uploadProgress
                            .activeBackgroundTransfer?
                            .id == context.id
                    else {
                        return
                    }

                    job.stage = .readyToUpload
                    job.uploadProgress.activeBackgroundTransfer = nil
                    job.uploadProgress.currentFilename = nil
                    job.uploadProgress.currentStep = nil
                    job.uploadProgress.pauseRequested = false
                    job.uploadProgress.pausedAt =
                        shouldRemainPaused ? Date() : nil
                    job.uploadProgress.currentRunStartedAt = nil
                    job.uploadProgress
                        .backgroundTransferNeedsReconciliation =
                            true
                    job.uploadProgress.errorMessage =
                        shouldRemainPaused
                        ? "The background transfer ended while PickPic was closed. Uploading remains paused and will be safely verified when you resume."
                        : "The saved background transfer is no longer active. PickPic will safely verify it and continue."
                    job.updatedAt = Date()
                }

                if !shouldRemainPaused {
                    jobIDsToResume.append(jobID)
                }
            } catch {
                loadErrorMessage =
                    "PickPic could not reconcile a background upload: \(error.localizedDescription)"
            }
        }

        guard
            resumeIfActive,
            configuration.isConfigured
        else {
            return
        }

        for jobID in jobIDsToResume {
            await runUploadPipeline(
                jobID: jobID,
                using: configuration
            )
        }
    }

    func handleRestoredBackgroundUploadCompletion(
        _ completion: BackgroundUploadCompletion,
        using configuration: APIConfigurationStore,
        resumeIfActive: Bool
    ) async {
        let context = completion.context

        guard
            jobs.first(where: { job in
                job.id == context.jobID
            })?
            .uploadProgress
            .activeBackgroundTransfer?
            .id == context.id
        else {
            return
        }

        let shouldRemainPaused =
            jobs.first(where: { job in
                job.id == context.jobID
            })?.uploadProgress.isPauseRequested == true

        let failureMessage: String?

        if completion.succeeded {
            failureMessage = nil
        } else if completion
            .shouldRetryWhenConnectivityReturns
        {
            failureMessage =
                "The background upload lost its internet connection. PickPic will retry when connectivity returns."
        } else if let statusCode = completion.statusCode {
            failureMessage =
                "The background upload returned HTTP \(statusCode). Open PickPic to retry this photo."
        } else {
            failureMessage = completion.errorMessage
                ?? "The background upload ended before PickPic received a server response."
        }

        do {
            try updateJob(context.jobID) { job in
                guard
                    job.uploadProgress
                        .activeBackgroundTransfer?
                        .id == context.id
                else {
                    return
                }

                job.stage = .readyToUpload
                job.uploadProgress.activeBackgroundTransfer = nil
                job.uploadProgress.currentFilename = nil
                job.uploadProgress.currentStep = nil
                job.uploadProgress.pauseRequested = false
                job.uploadProgress.pausedAt =
                    completion.succeeded
                    && shouldRemainPaused
                    ? completion.completedAt
                    : nil
                job.uploadProgress.currentRunStartedAt = nil
                job.uploadProgress
                    .waitingForConnectivitySince = nil

                if completion.succeeded {
                    job.uploadProgress.lastFailure = nil
                    job.uploadProgress.errorMessage =
                        shouldRemainPaused
                        ? "A background transfer finished while PickPic was not running. Uploading is paused and will be safely verified when you resume."
                        : "A background transfer finished while PickPic was not running. PickPic will verify it and continue without creating a duplicate."
                    job.uploadProgress
                        .backgroundTransferNeedsReconciliation =
                            true
                } else {
                    let message = failureMessage
                        ?? "The background upload failed."

                    job.uploadProgress.errorMessage = message
                    let retryForConnectivity =
                        completion
                            .shouldRetryWhenConnectivityReturns

                    job.uploadProgress.lastFailure = UploadFailure(
                        sourceFilename: context.sourceFilename,
                        step: context.step,
                        message: message,
                        occurredAt: completion.completedAt,
                        isNetworkRelated:
                            retryForConnectivity,
                        retryWhenConnectivityReturns:
                            retryForConnectivity
                    )
                    job.uploadProgress
                        .waitingForConnectivitySince =
                            retryForConnectivity
                            ? completion.completedAt
                            : nil
                    job.uploadProgress
                        .backgroundTransferNeedsReconciliation =
                            false
                }

                job.updatedAt = completion.completedAt
            }
        } catch {
            loadErrorMessage =
                "PickPic could not save the completed background upload: \(error.localizedDescription)"
            return
        }

        guard
            completion.succeeded,
            !shouldRemainPaused,
            resumeIfActive,
            configuration.isConfigured
        else {
            return
        }

        await runUploadPipeline(
            jobID: context.jobID,
            using: configuration
        )
    }

    func resumeBackgroundReconciliationJobs(
        using configuration: APIConfigurationStore
    ) async {
        let jobIDs = jobs
            .filter { job in
                job.stage == .readyToUpload
                && !job.uploadProgress.isPaused
                && job.uploadProgress
                    .backgroundTransferNeedsReconciliation
            }
            .sorted { first, second in
                first.createdAt < second.createdAt
            }
            .map(\.id)

        for jobID in jobIDs {
            guard !Task.isCancelled else {
                return
            }

            await runUploadPipeline(
                jobID: jobID,
                using: configuration
            )
        }
    }

    func retryLastFailedPhoto(
        jobID: UUID,
        using configuration: APIConfigurationStore
    ) async {
        guard
            let job = jobs.first(
                where: { job in
                    job.id == jobID
                }
            ),
            job.stage == .readyToUpload,
            let failedFilename =
                job.uploadProgress
                    .lastFailure?
                    .sourceFilename
        else {
            return
        }

        await uploadAllPhotos(
            jobID: jobID,
            using: configuration,
            onlySourceFilename: failedFilename
        )
    }

    func removeCompletedJobs(
        for eventID: String
    ) throws {
        let completedJobIDs = Set(
            jobs
                .filter { job in
                    job.eventID == eventID
                    && job.stage == .completed
                }
                .map(\.id)
        )

        guard !completedJobIDs.isEmpty else {
            return
        }

        try remove(
            jobIDs: completedJobIDs
        )
    }

    func add(
        _ job: UploadJob
    ) throws {
        var updatedJobs = jobs
        updatedJobs.append(job)

        updatedJobs.sort { first, second in
            first.createdAt > second.createdAt
        }

        try save(updatedJobs)

        jobs = updatedJobs
        loadErrorMessage = nil
    }

    func remove(
        jobIDs: Set<UUID>
    ) throws {
        let removedJobs = jobs.filter { job in
            jobIDs.contains(job.id)
        }

        let updatedJobs = jobs.filter { job in
            !jobIDs.contains(job.id)
        }

        try save(updatedJobs)

        jobs = updatedJobs
        loadErrorMessage = nil

        runningPipelineJobIDs.subtract(jobIDs)
        pauseRequestedJobIDs.subtract(jobIDs)

        for jobID in jobIDs {
            activeConnectivityOperationIDs.removeValue(
                forKey: jobID
            )

            activeContinuedProcessingTasks[
                jobID
            ]?.operationTask.cancel()
            activeContinuedProcessingTasks.removeValue(
                forKey: jobID
            )

            ContinuedProcessingTaskCoordinator
                .shared
                .cancel(jobID: jobID)
        }

        for job in removedJobs {
            if let context = job.uploadProgress
                .activeBackgroundTransfer
            {
                BackgroundUploadSession.shared.cancel(
                    contextID: context.id
                )
            }

            try? ImageConversionService
                .removePreview(
                    for: job.id
                )

            try? ImageConversionService
                .removePreparedPhotos(
                    for: job.id
                )
        }
    }

    func relinkFolder(
        for jobID: UUID,
        to folderURL: URL
    ) async throws -> UploadJob {
        guard let currentJob = jobs.first(
            where: { job in
                job.id == jobID
            }
        ) else {
            throw UploadFolderRelinkError.jobNotFound
        }

        switch currentJob.stage {
        case .preparing,
                .converting,
                .uploading:
            throw UploadFolderRelinkError
                .operationInProgress

        case .queued,
                .prepared,
                .readyToUpload,
                .completed,
                .failed:
            break
        }

        let relinkedFolder = try await Task.detached(
            priority: .userInitiated
        ) {
            try Self.validateRelinkedFolder(
                folderURL,
                for: currentJob
            )
        }
        .value

        try updateJob(jobID) { job in
            job.folderName = relinkedFolder.name
            job.folderBookmarkData =
                relinkedFolder.bookmarkData
            job.errorMessage = nil
            job.updatedAt = Date()
        }

        guard let updatedJob = jobs.first(
            where: { job in
                job.id == jobID
            }
        ) else {
            throw UploadFolderRelinkError.jobNotFound
        }

        return updatedJob
    }

    func prepare(
        jobID: UUID
    ) async {
        guard
            let currentJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            ),
            currentJob.stage == .queued
                || currentJob.stage == .failed
        else {
            return
        }

        do {
            try updateJob(jobID) { job in
                job.stage = .preparing
                job.errorMessage = nil
                job.updatedAt = Date()
            }
        } catch {
            loadErrorMessage =
                """
                The upload job could not be updated: \
                \(error.localizedDescription)
                """

            return
        }

        guard
            let preparingJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            )
        else {
            return
        }

        do {
            let result = try await Task.detached(
                priority: .userInitiated
            ) {
                try UploadPreparationService.prepare(
                    job: preparingJob
                )
            }.value

            try updateJob(jobID) { job in
                job.stage = .prepared
                job.preparedAt = result.preparedAt
                job.errorMessage = nil
                job.updatedAt = result.preparedAt
            }
        } catch {
            let preparationError =
            error.localizedDescription

            do {
                try updateJob(jobID) { job in
                    job.stage = .failed
                    job.errorMessage =
                    preparationError
                    job.updatedAt = Date()
                }
            } catch {
                loadErrorMessage =
                    """
                    Preparation failed, and the upload \
                    job could not be saved: \
                    \(error.localizedDescription)
                    """
            }
        }
    }

    func convertTestPreview(
        jobID: UUID
    ) async {
        guard
            let currentJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            ),
            currentJob.stage == .prepared
        else {
            return
        }

        do {
            try updateJob(jobID) { job in
                job.stage = .converting
                job.conversionErrorMessage = nil
                job.updatedAt = Date()
            }
        } catch {
            loadErrorMessage =
            """
            The conversion could not start: \
            \(error.localizedDescription)
            """

            return
        }

        guard
            let convertingJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            )
        else {
            return
        }

        do {
            let preview = try await Task.detached(
                priority: .userInitiated
            ) {
                try autoreleasepool {
                    try ImageConversionService
                        .createTestPreview(
                            for: convertingJob
                        )
                }
            }.value

            try updateJob(jobID) { job in
                job.stage = .prepared
                job.conversionPreview = preview
                job.conversionErrorMessage = nil
                job.updatedAt = preview.convertedAt
            }
        } catch {
            let conversionError =
            error.localizedDescription

            do {
                try updateJob(jobID) { job in
                    job.stage = .prepared
                    job.conversionErrorMessage =
                    conversionError
                    job.updatedAt = Date()
                }
            } catch {
                loadErrorMessage =
                """
                Conversion failed, and the job \
                could not be saved: \
                \(error.localizedDescription)
                """
            }
        }
    }

    func convertAllPhotos(
        jobID: UUID
    ) async {
        guard
            let currentJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            ),
            currentJob.stage == .prepared
                || currentJob.stage
                == .readyToUpload
        else {
            return
        }

        let shouldRestartFromBeginning =
        currentJob.stage == .readyToUpload

        let recoveredPreparedPhotos =
        shouldRestartFromBeginning
        ? []
        : ImageConversionService
            .availablePreparedPhotos(
                for: currentJob
            )

        do {
            try await Task.detached(
                priority: .utility
            ) {
                try AppStorageService
                    .ensureProofBatchCapacity(
                        photoCount:
                            currentJob.photoCount
                    )
            }
            .value
        } catch {
            do {
                try updateJob(jobID) { job in
                    job.conversionErrorMessage =
                    error.localizedDescription

                    job.updatedAt = Date()
                }
            } catch {
                loadErrorMessage =
            """
            Storage could not be checked, and the \
            queue could not be updated: \
            \(error.localizedDescription)
            """
            }

            return
        }

        let startedAt = Date()

        let sourceFilenames = Set(
            currentJob.photos.map(\.filename)
        )

        let preservedCompletedFilenames =
        currentJob.uploadProgress
            .completedSourceFilenames
            .intersection(sourceFilenames)

        let preservedDuplicateFilenames =
        currentJob.uploadProgress
            .duplicateSourceFilenames
            .intersection(sourceFilenames)

        let preservedOptimizedFilenames =
        currentJob.uploadProgress
            .optimizedSourceFilenames
            .intersection(sourceFilenames)

        let preservedActiveUploadDuration =
        currentJob.uploadProgress
            .activeUploadDuration

        do {
            try updateJob(jobID) { job in
                job.stage = .converting
                job.preparedPhotos =
                    recoveredPreparedPhotos
                job.conversionProcessedCount =
                    recoveredPreparedPhotos.count
                job.conversionCurrentFilename = nil
                job.conversionStartedAt = startedAt
                job.conversionCompletedAt = nil
                job.conversionErrorMessage = nil
                job.uploadProgress = UploadProgress(
                    completedSourceFilenames:
                        preservedCompletedFilenames,
                    duplicateSourceFilenames:
                        preservedDuplicateFilenames,
                    currentFilename: nil,
                    startedAt:
                        currentJob.uploadProgress
                            .startedAt,
                    completedAt: nil,
                    errorMessage: nil,
                    optimizedSourceFilenames:
                        preservedOptimizedFilenames,
                    activeUploadDuration:
                        preservedActiveUploadDuration
                )
                job.updatedAt = startedAt
            }
        } catch {
            loadErrorMessage =
            """
            Batch conversion could not start: \
            \(error.localizedDescription)
            """

            return
        }

        guard
            let convertingJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            )
        else {
            return
        }

        do {
            if
                shouldRestartFromBeginning
                || recoveredPreparedPhotos.isEmpty
            {
                try await Task.detached(
                    priority: .utility
                ) {
                    try ImageConversionService
                        .resetPreparedPhotos(
                            for: jobID
                        )
                }.value
            }

            var completedSourcePhotoIDs = Set(
                recoveredPreparedPhotos
                    .compactMap(\.sourcePhotoID)
            )

            for (
                index,
                sourcePhoto
            ) in convertingJob.photos.enumerated() {
                try Task.checkCancellation()

                guard
                    !completedSourcePhotoIDs
                        .contains(sourcePhoto.id)
                else {
                    continue
                }

                try updateJob(jobID) { job in
                    job.conversionCurrentFilename =
                    sourcePhoto.filename
                    job.updatedAt = Date()
                }

                let preparedPhoto =
                try await Task.detached(
                    priority: .userInitiated
                ) {
                    try autoreleasepool {
                        try ImageConversionService
                            .createPreparedPhoto(
                                sourcePhoto: sourcePhoto,
                                index: index,
                                job: convertingJob
                            )
                    }
                }.value

                try updateJob(jobID) { job in
                    job.preparedPhotos.append(
                        preparedPhoto
                    )

                    job.conversionProcessedCount =
                    job.preparedPhotos.count

                    job.updatedAt =
                    preparedPhoto.preparedAt
                }

                completedSourcePhotoIDs.insert(
                    sourcePhoto.id
                )
            }

            let completedAt = Date()

            try updateJob(jobID) { job in
                job.stage = .readyToUpload
                job.conversionCurrentFilename =
                nil
                job.conversionCompletedAt =
                completedAt
                job.conversionErrorMessage =
                nil
                job.updatedAt = completedAt
            }
        } catch {
            let latestJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            )

            let savedPreparedPhotos = latestJob.map { job in
                ImageConversionService
                    .availablePreparedPhotos(
                        for: job
                    )
            }
            ?? []

            let failedFilename = latestJob?
                .conversionCurrentFilename

            let interruptionDescription: String

            if error is CancellationError {
                interruptionDescription =
                    "Batch conversion was interrupted."
            } else if let failedFilename {
                interruptionDescription =
                """
                RAW conversion stopped at \(failedFilename). \
                \(error.localizedDescription)
                """
            } else {
                interruptionDescription =
                    error.localizedDescription
            }

            let recoveryDescription: String

            if savedPreparedPhotos.isEmpty {
                recoveryDescription =
                    "Start the conversion again."
            } else {
                recoveryDescription =
                """
                PickPic saved \(savedPreparedPhotos.count) of \
                \(currentJob.photoCount) converted photos. Continue \
                the upload to resume with the remaining photos.
                """
            }

            let conversionError =
                "\(interruptionDescription) \(recoveryDescription)"

            do {
                try updateJob(jobID) { job in
                    job.stage = .prepared
                    job.preparedPhotos =
                        savedPreparedPhotos
                    job.conversionProcessedCount =
                        savedPreparedPhotos.count
                    job.conversionCurrentFilename =
                        nil
                    job.conversionCompletedAt =
                        nil
                    job.conversionErrorMessage =
                        conversionError
                    job.updatedAt = Date()
                }
            } catch {
                loadErrorMessage =
                """
                Conversion failed, and the queue \
                could not be updated: \
                \(error.localizedDescription)
                """
            }
        }
    }

    func uploadAllPhotos(
        jobID: UUID,
        using configuration:
        APIConfigurationStore,
        onlySourceFilename: String? = nil
    ) async {
        guard
            let currentJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            ),
            currentJob.stage == .readyToUpload
        else {
            return
        }

        guard
            !currentJob.preparedPhotos.isEmpty,
            currentJob.preparedPhotos.count
                == currentJob.photoCount
        else {
            do {
                try updateJob(jobID) { job in
                    job.uploadProgress.errorMessage =
                    """
                    The prepared batch is incomplete. \
                    Convert all photos again.
                    """

                    job.uploadProgress.lastFailure = nil

                    job.updatedAt = Date()
                }
            } catch {
                loadErrorMessage =
                    error.localizedDescription
            }

            return
        }

        let preparedPhotos: [PreparedPhoto]

        if let onlySourceFilename {
            preparedPhotos = currentJob.preparedPhotos
                .filter { photo in
                    photo.sourceFilename
                        .caseInsensitiveCompare(
                            onlySourceFilename
                        ) == .orderedSame
                }

            guard !preparedPhotos.isEmpty else {
                return
            }
        } else {
            preparedPhotos = currentJob.preparedPhotos
        }

        let client: APIClient

        do {
            client = try configuration.makeClient()
        } catch {
            do {
                try updateJob(jobID) { job in
                    job.uploadProgress.errorMessage =
                        error.localizedDescription

                    job.uploadProgress.lastFailure = nil
                    job.uploadProgress.pausedAt = nil

                    job.updatedAt = Date()
                }
            } catch {
                loadErrorMessage =
                    error.localizedDescription
            }

            return
        }

        let startedAt =
        currentJob.uploadProgress.startedAt
        ?? Date()

        let runStartedAt = Date()

        pauseRequestedJobIDs.remove(jobID)

        do {
            try updateJob(jobID) { job in
                job.stage = .uploading

                job.uploadProgress.startedAt =
                    startedAt

                job.uploadProgress.completedAt = nil
                job.uploadProgress.currentFilename = nil
                job.uploadProgress.currentStep = nil
                job.uploadProgress.errorMessage = nil
                job.uploadProgress.lastFailure = nil
                job.uploadProgress.pauseRequested = false
                job.uploadProgress.pausedAt = nil
                job.uploadProgress
                    .waitingForConnectivitySince = nil
                job.uploadProgress.activeBackgroundTransfer = nil
                job.uploadProgress
                    .backgroundTransferNeedsReconciliation = false
                job.uploadProgress.currentRunStartedAt =
                    runStartedAt

                job.updatedAt = runStartedAt
            }
        } catch {
            loadErrorMessage =
            """
            Uploading could not start: \
            \(error.localizedDescription)
            """

            return
        }

        guard
            let uploadingJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            )
        else {
            return
        }

        var completedFilenames =
        uploadingJob
            .uploadProgress
            .completedSourceFilenames

        let allSourceFilenames = Set(
            uploadingJob.preparedPhotos.map(
                \.sourceFilename
            )
        )

        for preparedPhoto in preparedPhotos {
            if Task.isCancelled {
                transitionUploadToReady(
                    jobID: jobID,
                    message:
                        "Uploading was cancelled. Resume the remaining photos."
                )
                return
            }

            if completedFilenames.contains(
                preparedPhoto.sourceFilename
            ) {
                continue
            }

            if
                pauseRequestedJobIDs.contains(jobID),
                !completedFilenames.isSuperset(
                    of: allSourceFilenames
                )
            {
                pauseUpload(jobID: jobID)
                return
            }

            do {
                try updateJob(jobID) { job in
                    job.uploadProgress.currentFilename =
                        preparedPhoto.sourceFilename

                    job.uploadProgress.currentStep =
                        .proofUpload

                    job.uploadProgress.errorMessage = nil
                    job.updatedAt = Date()
                }
            } catch {
                loadErrorMessage =
                    error.localizedDescription

                return
            }

            let fileURL =
            ImageConversionService
                .preparedPhotoURL(
                    jobID: jobID,
                    outputFilename:
                        preparedPhoto.outputFilename
                )

            do {
                let connectivityOperationID =
                    beginConnectivityOperation(
                        for: jobID
                    )

                defer {
                    finishConnectivityOperation(
                        for: jobID,
                        operationID:
                            connectivityOperationID
                    )
                }

                let outcome: PhotoUploadOutcome

                do {
                    let backgroundContext =
                        try beginBackgroundTransfer(
                            jobID: jobID,
                            sourceFilename:
                                preparedPhoto.sourceFilename,
                            step: .proofUpload
                        )

                    defer {
                        clearBackgroundTransfer(
                            jobID: jobID,
                            contextID:
                                backgroundContext.id
                        )
                    }

                    outcome = try await client
                        .uploadPreparedPhoto(
                            preparedPhoto,
                            from: fileURL,
                            to: uploadingJob.eventID,
                            backgroundContext:
                                backgroundContext,
                            connectivityCallbacks:
                                connectivityCallbacks(
                                    for: jobID,
                                    operationID:
                                        connectivityOperationID
                                )
                        )
                }

                let isDuplicate: Bool
                let photoID: String
                let shouldUploadOriginalVariants: Bool

                switch outcome {
                case let .uploaded(uploadedPhotoID):
                    isDuplicate = false
                    photoID = uploadedPhotoID
                    shouldUploadOriginalVariants = true

                case let .duplicate(
                    existingPhotoID,
                    variant
                ):
                    isDuplicate = true
                    photoID = existingPhotoID
                    shouldUploadOriginalVariants =
                        variant != "final"
                }

                if shouldUploadOriginalVariants {
                    try await uploadOriginalVariants(
                        from: fileURL,
                        photoID: photoID,
                        sourceFilename:
                            preparedPhoto.sourceFilename,
                        jobID: jobID,
                        using: client
                    )
                }

                completedFilenames.insert(
                    preparedPhoto.sourceFilename
                )

                try updateJob(jobID) { job in
                    job.uploadProgress
                        .completedSourceFilenames
                        .insert(
                            preparedPhoto
                                .sourceFilename
                        )

                    if isDuplicate {
                        job.uploadProgress
                            .duplicateSourceFilenames
                            .insert(
                                preparedPhoto
                                    .sourceFilename
                            )
                    }

                    if shouldUploadOriginalVariants {
                        job.uploadProgress
                            .optimizedSourceFilenames
                            .insert(
                                preparedPhoto
                                    .sourceFilename
                            )
                    }

                    job.uploadProgress.currentFilename = nil
                    job.uploadProgress.currentStep = nil
                    job.uploadProgress.errorMessage = nil
                    job.uploadProgress.lastFailure = nil
                    job.uploadProgress
                        .waitingForConnectivitySince = nil
                    job.updatedAt = Date()
                }
            } catch {
                let failure = makeUploadFailure(
                    error,
                    sourceFilename:
                        preparedPhoto.sourceFilename
                )

                do {
                    try updateJob(jobID) { job in
                        job.stage = .readyToUpload
                        job.uploadProgress.currentFilename = nil
                        job.uploadProgress.currentStep = nil
                        job.uploadProgress.errorMessage =
                            failure.message
                        job.uploadProgress.lastFailure =
                            failure
                        job.uploadProgress.pauseRequested = false
                        job.uploadProgress.pausedAt = nil

                        let stoppedAt = Date()
                        job.uploadProgress
                            .waitingForConnectivitySince =
                                failure
                                    .shouldRetryWhenConnectivityReturns
                                ? stoppedAt
                                : nil
                        stopActiveUploadTimer(
                            &job.uploadProgress,
                            at: stoppedAt
                        )
                        job.updatedAt = stoppedAt
                    }
                } catch {
                    loadErrorMessage =
                    """
                    Uploading failed, and the queue \
                    could not be saved: \
                    \(error.localizedDescription)
                    """
                }

                pauseRequestedJobIDs.remove(jobID)
                return
            }

            if onlySourceFilename != nil {
                break
            }

            if
                pauseRequestedJobIDs.contains(jobID),
                !completedFilenames.isSuperset(
                    of: allSourceFilenames
                )
            {
                pauseUpload(jobID: jobID)
                return
            }
        }

        guard
            let refreshedJob = jobs.first(
                where: { job in
                    job.id == jobID
                }
            )
        else {
            return
        }

        let allPhotosCompleted =
        refreshedJob.uploadProgress
            .completedSourceFilenames
            .isSuperset(of: allSourceFilenames)

        if !allPhotosCompleted {
            pauseRequestedJobIDs.remove(jobID)

            do {
                try updateJob(jobID) { job in
                    job.stage = .readyToUpload
                    job.uploadProgress.currentFilename = nil
                    job.uploadProgress.currentStep = nil
                    job.uploadProgress.errorMessage = nil
                    job.uploadProgress.pauseRequested = false
                    job.uploadProgress.pausedAt = nil
                    job.uploadProgress
                        .waitingForConnectivitySince = nil

                    let stoppedAt = Date()
                    stopActiveUploadTimer(
                        &job.uploadProgress,
                        at: stoppedAt
                    )
                    job.updatedAt = stoppedAt
                }
            } catch {
                loadErrorMessage =
                """
                The photo retry finished, but the queue could not be \
                updated: \(error.localizedDescription)
                """
            }

            return
        }

        let completedAt = Date()

        do {
            try updateJob(jobID) { job in
                job.stage = .completed
                job.uploadProgress.currentFilename = nil
                job.uploadProgress.currentStep = nil
                job.uploadProgress.completedAt = completedAt
                job.uploadProgress.errorMessage = nil
                job.uploadProgress.lastFailure = nil
                job.uploadProgress.pauseRequested = false
                job.uploadProgress.pausedAt = nil
                job.uploadProgress
                    .waitingForConnectivitySince = nil
                stopActiveUploadTimer(
                    &job.uploadProgress,
                    at: completedAt
                )
                job.updatedAt = completedAt
            }
        } catch {
            loadErrorMessage =
            """
            Uploading finished, but completion \
            could not be saved: \
            \(error.localizedDescription)
            """

            return
        }

        pauseRequestedJobIDs.remove(jobID)

        try? ImageConversionService
            .removePreparedPhotos(
                for: jobID
            )
    }

    private func uploadOriginalVariants(
        from sourceURL: URL,
        photoID: String,
        sourceFilename: String,
        jobID: UUID,
        using client: APIClient
    ) async throws {
        let outputDirectoryURL =
        AppStorageService.imageVariantStagingURL
            .appendingPathComponent(
                jobID.uuidString,
                isDirectory: true
            )
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )

        defer {
            try? FileManager.default.removeItem(
                at: outputDirectoryURL
            )
        }

        do {
            try updateJob(jobID) { job in
                job.uploadProgress.currentStep =
                    .variantGeneration
                job.updatedAt = Date()
            }
        } catch {
            throw error
        }

        let variants: GeneratedFinalVariants

        do {
            variants = try await Task.detached(
                priority: .utility
            ) {
                try autoreleasepool {
                    try ImageVariantService
                        .createImageVariants(
                            from: sourceURL,
                            outputDirectoryURL:
                                outputDirectoryURL
                        )
                }
            }
            .value
        } catch {
            throw UploadQueuePipelineError
                .variantGenerationFailed(
                    filename: sourceFilename,
                    reason:
                        error.localizedDescription
                )
        }

        try updateJob(jobID) { job in
            job.uploadProgress.currentStep =
                .variantUpload
            job.updatedAt = Date()
        }

        do {
            let connectivityOperationID =
                beginConnectivityOperation(
                    for: jobID
                )

            defer {
                finishConnectivityOperation(
                    for: jobID,
                    operationID:
                        connectivityOperationID
                )
            }

            let backgroundContext =
                try beginBackgroundTransfer(
                    jobID: jobID,
                    sourceFilename: sourceFilename,
                    step: .variantUpload
                )

            defer {
                clearBackgroundTransfer(
                    jobID: jobID,
                    contextID: backgroundContext.id
                )
            }

            _ = try await client.uploadImageVariants(
                variants,
                sourceKind: .original,
                to: photoID,
                backgroundContext: backgroundContext,
                connectivityCallbacks:
                    connectivityCallbacks(
                        for: jobID,
                        operationID:
                            connectivityOperationID
                    )
            )
        } catch {
            let friendlyError = friendlyUploadError(
                error,
                sourceFilename: sourceFilename
            )

            throw UploadQueuePipelineError
                .variantUploadFailed(
                    filename: sourceFilename,
                    reason: friendlyError.message,
                    isNetworkRelated:
                        friendlyError.isNetworkRelated,
                    retryWhenConnectivityReturns:
                        friendlyError
                            .retryWhenConnectivityReturns
                )
        }
    }

    private func pauseUpload(
        jobID: UUID
    ) {
        pauseRequestedJobIDs.remove(jobID)

        do {
            try updateJob(jobID) { job in
                job.stage = .readyToUpload
                job.uploadProgress.currentFilename = nil
                job.uploadProgress.currentStep = nil
                job.uploadProgress.errorMessage = nil
                job.uploadProgress.pauseRequested = false
                job.uploadProgress
                    .waitingForConnectivitySince = nil

                let pausedAt = Date()
                job.uploadProgress.pausedAt = pausedAt
                stopActiveUploadTimer(
                    &job.uploadProgress,
                    at: pausedAt
                )
                job.updatedAt = pausedAt
            }
        } catch {
            loadErrorMessage =
            """
            Uploading paused, but the queue could not be saved: \
            \(error.localizedDescription)
            """
        }
    }

    private func transitionUploadToReady(
        jobID: UUID,
        message: String
    ) {
        pauseRequestedJobIDs.remove(jobID)

        do {
            try updateJob(jobID) { job in
                job.stage = .readyToUpload
                job.uploadProgress.currentFilename = nil
                job.uploadProgress.currentStep = nil
                job.uploadProgress.errorMessage = message
                job.uploadProgress.pauseRequested = false
                job.uploadProgress.pausedAt = nil
                job.uploadProgress
                    .waitingForConnectivitySince = nil

                let stoppedAt = Date()
                stopActiveUploadTimer(
                    &job.uploadProgress,
                    at: stoppedAt
                )
                job.updatedAt = stoppedAt
            }
        } catch {
            loadErrorMessage =
            """
            Uploading stopped, but the queue could not be saved: \
            \(error.localizedDescription)
            """
        }
    }

    private func beginBackgroundTransfer(
        jobID: UUID,
        sourceFilename: String,
        step: UploadOperationStep
    ) throws -> BackgroundUploadContext {
        let context = BackgroundUploadContext(
            jobID: jobID,
            sourceFilename: sourceFilename,
            step: step
        )

        try updateJob(jobID) { job in
            job.uploadProgress.activeBackgroundTransfer =
                context
            job.updatedAt = Date()
        }

        return context
    }

    private func clearBackgroundTransfer(
        jobID: UUID,
        contextID: UUID
    ) {
        guard
            jobs.first(where: { job in
                job.id == jobID
            })?
            .uploadProgress
            .activeBackgroundTransfer?
            .id == contextID
        else {
            return
        }

        do {
            try updateJob(jobID) { job in
                guard
                    job.uploadProgress
                        .activeBackgroundTransfer?
                        .id == contextID
                else {
                    return
                }

                job.uploadProgress.activeBackgroundTransfer = nil
                job.updatedAt = Date()
            }
        } catch {
            loadErrorMessage =
                "PickPic could not clear the saved background transfer: \(error.localizedDescription)"
        }
    }

    private func beginConnectivityOperation(
        for jobID: UUID
    ) -> UUID {
        let operationID = UUID()
        activeConnectivityOperationIDs[jobID] =
            operationID
        return operationID
    }

    private func finishConnectivityOperation(
        for jobID: UUID,
        operationID: UUID
    ) {
        guard
            activeConnectivityOperationIDs[jobID]
                == operationID
        else {
            return
        }

        activeConnectivityOperationIDs.removeValue(
            forKey: jobID
        )
    }

    private func connectivityCallbacks(
        for jobID: UUID,
        operationID: UUID
    ) -> UploadConnectivityCallbacks {
        UploadConnectivityCallbacks(
            onWaiting: { [weak self] in
                DispatchQueue.main.async {
                    self?.markWaitingForConnectivity(
                        jobID: jobID,
                        operationID: operationID
                    )
                }
            },
            onResumed: { [weak self] in
                DispatchQueue.main.async {
                    self?.markConnectivityResumed(
                        jobID: jobID,
                        operationID: operationID
                    )
                }
            }
        )
    }

    private func markWaitingForConnectivity(
        jobID: UUID,
        operationID: UUID
    ) {
        guard
            activeConnectivityOperationIDs[jobID]
                == operationID,
            jobs.first(where: { job in
                job.id == jobID
            })?.stage == .uploading
        else {
            return
        }

        let waitingSince = Date()

        do {
            try updateJob(jobID) { job in
                guard
                    !job.uploadProgress
                        .isWaitingForConnectivity
                else {
                    return
                }

                stopActiveUploadTimer(
                    &job.uploadProgress,
                    at: waitingSince
                )

                job.uploadProgress
                    .waitingForConnectivitySince =
                        waitingSince
                job.uploadProgress.errorMessage =
                    "Waiting for an internet connection. PickPic will continue automatically."
                job.updatedAt = waitingSince
            }
        } catch {
            loadErrorMessage =
                "PickPic could not save the waiting-for-network state: \(error.localizedDescription)"
        }
    }

    private func markConnectivityResumed(
        jobID: UUID,
        operationID: UUID
    ) {
        guard
            activeConnectivityOperationIDs[jobID]
                == operationID,
            let job = jobs.first(where: { job in
                job.id == jobID
            }),
            job.stage == .uploading,
            job.uploadProgress
                .isWaitingForConnectivity
        else {
            return
        }

        let resumedAt = Date()

        do {
            try updateJob(jobID) { job in
                job.uploadProgress
                    .waitingForConnectivitySince = nil
                job.uploadProgress.errorMessage = nil
                job.uploadProgress.currentRunStartedAt =
                    resumedAt
                job.updatedAt = resumedAt
            }
        } catch {
            loadErrorMessage =
                "PickPic could not save the resumed upload state: \(error.localizedDescription)"
        }
    }

    private func stopActiveUploadTimer(
        _ progress: inout UploadProgress,
        at stoppedAt: Date
    ) {
        guard let runStartedAt =
            progress.currentRunStartedAt
        else {
            return
        }

        progress.activeUploadDuration += max(
            stoppedAt.timeIntervalSince(
                runStartedAt
            ),
            0
        )

        progress.currentRunStartedAt = nil
    }

    private func makeUploadFailure(
        _ error: Error,
        sourceFilename: String
    ) -> UploadFailure {
        let step: UploadOperationStep
        let message: String
        let isNetworkRelated: Bool
        let retryWhenConnectivityReturns: Bool

        if let pipelineError =
            error as? UploadQueuePipelineError
        {
            switch pipelineError {
            case let .variantGenerationFailed(
                _,
                reason
            ):
                step = .variantGeneration
                message = reason
                isNetworkRelated = false
                retryWhenConnectivityReturns = false

            case let .variantUploadFailed(
                _,
                reason,
                networkRelated,
                retriesWhenConnected
            ):
                step = .variantUpload
                message = reason
                isNetworkRelated = networkRelated
                retryWhenConnectivityReturns =
                    retriesWhenConnected
            }
        } else {
            step = .proofUpload

            let friendlyError = friendlyUploadError(
                error,
                sourceFilename: sourceFilename
            )

            message = friendlyError.message
            isNetworkRelated =
                friendlyError.isNetworkRelated
            retryWhenConnectivityReturns =
                friendlyError
                    .retryWhenConnectivityReturns
        }

        return UploadFailure(
            sourceFilename: sourceFilename,
            step: step,
            message: message,
            occurredAt: Date(),
            isNetworkRelated: isNetworkRelated,
            retryWhenConnectivityReturns:
                retryWhenConnectivityReturns
        )
    }

    private func friendlyUploadError(
        _ error: Error,
        sourceFilename: String
    ) -> (
        message: String,
        isNetworkRelated: Bool,
        retryWhenConnectivityReturns: Bool
    ) {
        let urlError: URLError?

        if let directError = error as? URLError {
            urlError = directError
        } else {
            let nsError = error as NSError

            if nsError.domain == NSURLErrorDomain {
                urlError = URLError(
                    _nsError: nsError
                )
            } else {
                urlError = nil
            }
        }

        guard let urlError else {
            return (
                error.localizedDescription,
                false,
                false
            )
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return (
                """
                No internet connection. PickPic saved the progress for \
                \(sourceFilename) and will retry automatically when a \
                connection is available.
                """,
                true,
                true
            )

        case .networkConnectionLost:
            return (
                """
                The connection was lost while uploading \
                \(sourceFilename). PickPic saved the completed photos and \
                will retry automatically when the network returns.
                """,
                true,
                true
            )

        case .timedOut:
            return (
                """
                Uploading \(sourceFilename) timed out. PickPic saved the \
                completed photos. Check the connection and retry this photo.
                """,
                true,
                false
            )

        case .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed:
            return (
                """
                PickPic could not reach the server while uploading \
                \(sourceFilename). Check the server address and connection, \
                then retry this photo.
                """,
                true,
                false
            )

        case .cancelled:
            return (
                "Uploading \(sourceFilename) was cancelled.",
                false,
                false
            )

        default:
            return (
                """
                A network error stopped \(sourceFilename): \
                \(urlError.localizedDescription)
                """,
                true,
                false
            )
        }
    }

    func runUploadPipeline(
        jobID: UUID,
        using configuration: APIConfigurationStore
    ) async {
        guard beginPipeline(jobID: jobID) else {
            return
        }

        defer {
            endPipeline(jobID: jobID)
        }

        guard await prepareAndConvertWithinPipeline(
            jobID: jobID
        ) else {
            return
        }

        guard stage(for: jobID) == .readyToUpload else {
            return
        }

        await uploadAllPhotos(
            jobID: jobID,
            using: configuration
        )
    }

    private func runPreparationAndConversionPipeline(
        jobID: UUID
    ) async -> Bool {
        guard beginPipeline(jobID: jobID) else {
            return false
        }

        defer {
            endPipeline(jobID: jobID)
        }

        return await prepareAndConvertWithinPipeline(
            jobID: jobID
        )
    }

    private func runReconversionPipeline(
        jobID: UUID
    ) async -> Bool {
        guard beginPipeline(jobID: jobID) else {
            return false
        }

        defer {
            endPipeline(jobID: jobID)
        }

        guard
            stage(for: jobID) == .prepared
                || stage(for: jobID) == .readyToUpload
        else {
            return false
        }

        await convertAllPhotos(jobID: jobID)

        return !Task.isCancelled
            && stage(for: jobID) == .readyToUpload
    }

    private func prepareAndConvertWithinPipeline(
        jobID: UUID
    ) async -> Bool {
        guard let startingStage = stage(for: jobID) else {
            return false
        }

        switch startingStage {
        case .queued,
                .failed:
            await prepare(jobID: jobID)

            guard !Task.isCancelled else {
                return false
            }

            guard stage(for: jobID) == .prepared else {
                return false
            }

        case .prepared,
                .readyToUpload:
            break

        case .preparing,
                .converting,
                .uploading,
                .completed:
            return false
        }

        if stage(for: jobID) == .prepared {
            await convertAllPhotos(jobID: jobID)

            guard !Task.isCancelled else {
                return false
            }
        }

        return stage(for: jobID) == .readyToUpload
    }

    private func beginPipeline(
        jobID: UUID
    ) -> Bool {
        guard !runningPipelineJobIDs.contains(jobID) else {
            return false
        }

        runningPipelineJobIDs.insert(jobID)
        return true
    }

    private func endPipeline(
        jobID: UUID
    ) {
        runningPipelineJobIDs.remove(jobID)
    }

    func runTestPreviewPipeline(
        jobID: UUID
    ) async {
        guard
            !runningPipelineJobIDs.contains(jobID)
        else {
            return
        }

        runningPipelineJobIDs.insert(jobID)

        defer {
            runningPipelineJobIDs.remove(jobID)
        }

        guard
            let startingStage = stage(for: jobID)
        else {
            return
        }

        switch startingStage {
        case .queued,
                .failed:
            await prepare(jobID: jobID)

            guard !Task.isCancelled else {
                return
            }

            guard stage(for: jobID) == .prepared else {
                return
            }

        case .prepared:
            break

        case .preparing,
                .converting,
                .readyToUpload,
                .uploading,
                .completed:
            return
        }

        await convertTestPreview(
            jobID: jobID
        )
    }

    private func stage(
        for jobID: UUID
    ) -> UploadStage? {
        jobs.first { job in
            job.id == jobID
        }?
            .stage
    }

    private func updateJob(
        _ jobID: UUID,
        change: (inout UploadJob) -> Void
    ) throws {
        guard
            let index = jobs.firstIndex(
                where: { job in
                    job.id == jobID
                }
            )
        else {
            return
        }

        var updatedJobs = jobs
        change(&updatedJobs[index])

        try save(updatedJobs)

        jobs = updatedJobs
        loadErrorMessage = nil

        updateContinuedProcessingProgress(
            for: updatedJobs[index]
        )
    }

    private func updateContinuedProcessingProgress(
        for job: UploadJob,
        task: BGContinuedProcessingTask? = nil,
        completedUnitOverride: Int? = nil
    ) {
        guard
            let backgroundTask = task
                ?? activeContinuedProcessingTasks[
                    job.id
                ]?.backgroundTask
        else {
            return
        }

        let totalUnitCount = Int64(
            max(job.photoCount, 1)
        )
        let completedUnitCount = Int64(
            min(
                max(
                    completedUnitOverride
                    ?? job.conversionProcessedCount,
                    0
                ),
                job.photoCount
            )
        )

        backgroundTask.progress.totalUnitCount =
            totalUnitCount
        backgroundTask.progress.completedUnitCount =
            completedUnitCount
        
        let completed = Int(completedUnitCount)
        let total = Int(totalUnitCount)

        switch job.continuedProcessing?.operation {
        case .prepareConvertAndUpload:
            backgroundTask.updateTitle(
                "Preparing \(job.eventTitle)",
                subtitle:
                    "\(completed) of \(total) photos converted"
            )

        case .reconvertOnly:
            backgroundTask.updateTitle(
                "Rebuilding \(job.eventTitle)",
                subtitle:
                    "\(completed) of \(total) photos reconverted"
            )

        case nil:
            break
        }
    }

    private func load() {
        guard FileManager.default.fileExists(
            atPath: storageURL.path
        ) else {
            jobs = []
            recoveryMessage = nil
            return
        }

        do {
            let data = try Data(
                contentsOf: storageURL
            )

            var decodedJobs = try JSONDecoder().decode(
                [UploadJob].self,
                from: data
            )

            var changedRecoveredState = false
            var interruptedJobCount = 0
            var resumedConversionJobCount = 0
            var unavailablePreparedBatchCount = 0
            var fullyRecoveredBatchCount = 0
            var restoredBackgroundTransferCount = 0
            var deferredContinuedProcessingCount = 0
            let recoveryDate = Date()

            for index in decodedJobs.indices {
                let originalStage =
                    decodedJobs[index].stage

                if var continuedProcessing =
                    decodedJobs[index].continuedProcessing
                {
                    ContinuedProcessingTaskCoordinator
                        .shared
                        .cancel(
                            jobID: decodedJobs[index].id
                        )

                    switch originalStage {
                    case .readyToUpload,
                            .uploading,
                            .completed:
                        decodedJobs[index]
                            .continuedProcessing = nil
                        changedRecoveredState = true

                    case .queued,
                            .preparing,
                            .prepared,
                            .converting,
                            .failed:
                        if continuedProcessing.status
                            != .deferred
                        {
                            continuedProcessing.status =
                                .deferred
                            continuedProcessing.endedAt =
                                recoveryDate
                            continuedProcessing.message =
                                "The previous iPadOS background-processing task ended. Saved work is ready to resume."
                            decodedJobs[index]
                                .continuedProcessing =
                                    continuedProcessing
                            changedRecoveredState = true
                            deferredContinuedProcessingCount += 1
                        }
                    }
                }

                switch originalStage {
                case .prepared,
                        .converting,
                        .readyToUpload,
                        .uploading:
                    let availablePreparedPhotos =
                    ImageConversionService
                        .availablePreparedPhotos(
                            for: decodedJobs[index]
                        )

                    if availablePreparedPhotos
                        != decodedJobs[index]
                            .preparedPhotos
                    {
                        decodedJobs[index]
                            .preparedPhotos =
                                availablePreparedPhotos
                        decodedJobs[index]
                            .conversionProcessedCount =
                                availablePreparedPhotos.count
                        changedRecoveredState = true
                    }

                case .queued,
                        .preparing,
                        .completed,
                        .failed:
                    break
                }

                switch originalStage {
                case .preparing:
                    decodedJobs[index].stage = .failed
                    decodedJobs[index].errorMessage =
                        """
                        Folder preparation was interrupted. \
                        Try the job again.
                        """
                    decodedJobs[index].updatedAt =
                        recoveryDate
                    changedRecoveredState = true
                    interruptedJobCount += 1

                case .converting:
                    let recoveredCount =
                        decodedJobs[index]
                            .preparedPhotos.count

                    decodedJobs[index].stage = .prepared
                    decodedJobs[index]
                        .conversionProcessedCount =
                            recoveredCount
                    decodedJobs[index]
                        .conversionCurrentFilename = nil
                    decodedJobs[index]
                        .conversionCompletedAt = nil

                    if recoveredCount > 0 {
                        decodedJobs[index]
                            .conversionErrorMessage =
                            """
                            Batch conversion was interrupted after \
                            \(recoveredCount) of \
                            \(decodedJobs[index].photoCount) photos. \
                            Continue the upload to resume with the \
                            remaining photos.
                            """
                        if recoveredCount
                            < decodedJobs[index].photoCount
                        {
                            resumedConversionJobCount += 1
                        }
                    } else {
                        decodedJobs[index]
                            .conversionErrorMessage =
                            """
                            Batch conversion was interrupted. \
                            Start the conversion again.
                            """
                    }

                    decodedJobs[index].updatedAt =
                        recoveryDate
                    changedRecoveredState = true
                    interruptedJobCount += 1

                case .uploading:
                    let wasWaitingForConnectivity =
                        decodedJobs[index]
                            .uploadProgress
                            .isWaitingForConnectivity

                    if let currentRunStartedAt =
                        decodedJobs[index]
                            .uploadProgress
                            .currentRunStartedAt
                    {
                        let lastSavedActivityDate = max(
                            decodedJobs[index].updatedAt,
                            currentRunStartedAt
                        )

                        stopActiveUploadTimer(
                            &decodedJobs[index]
                                .uploadProgress,
                            at: lastSavedActivityDate
                        )
                    }

                    decodedJobs[index]
                        .uploadProgress
                        .pausedAt = nil
                    decodedJobs[index]
                        .uploadProgress
                        .currentRunStartedAt = nil

                    if decodedJobs[index]
                        .uploadProgress
                        .activeBackgroundTransfer != nil
                    {
                        decodedJobs[index].stage =
                            .uploading
                        decodedJobs[index]
                            .uploadProgress
                            .errorMessage =
                            wasWaitingForConnectivity
                            ? """
                            PickPic restored a background upload that was \
                            waiting for connectivity. iPadOS will continue \
                            it when a connection is available.
                            """
                            : """
                            PickPic is reconnecting to an iPadOS background \
                            upload. You can continue using other apps.
                            """
                        decodedJobs[index]
                            .uploadProgress
                            .backgroundTransferNeedsReconciliation =
                                false
                        restoredBackgroundTransferCount += 1
                    } else {
                        decodedJobs[index]
                            .uploadProgress
                            .pauseRequested = false
                        decodedJobs[index].stage =
                            .readyToUpload
                        decodedJobs[index]
                            .uploadProgress
                            .currentFilename = nil
                        decodedJobs[index]
                            .uploadProgress
                            .currentStep = nil
                        decodedJobs[index]
                            .uploadProgress
                            .errorMessage =
                            wasWaitingForConnectivity
                            ? """
                            PickPic was waiting for an internet connection \
                            when it closed. It will retry automatically when \
                            a connection is available.
                            """
                            : """
                            Uploading was interrupted. \
                            Resume the remaining photos.
                            """
                        decodedJobs[index]
                            .uploadProgress
                            .backgroundTransferNeedsReconciliation =
                                false

                        if !wasWaitingForConnectivity {
                            decodedJobs[index]
                                .uploadProgress
                                .waitingForConnectivitySince = nil
                        }

                        interruptedJobCount += 1
                    }

                    decodedJobs[index].updatedAt =
                        recoveryDate
                    changedRecoveredState = true

                case .queued,
                        .prepared,
                        .readyToUpload,
                        .completed,
                        .failed:
                    break
                }

                if
                    decodedJobs[index].stage
                        == .readyToUpload,
                    decodedJobs[index].preparedPhotos
                        .count
                        != decodedJobs[index].photoCount
                {
                    let recoveredCount =
                        decodedJobs[index]
                            .preparedPhotos.count

                    decodedJobs[index].stage = .prepared
                    decodedJobs[index]
                        .conversionProcessedCount =
                            recoveredCount
                    decodedJobs[index]
                        .conversionCurrentFilename = nil
                    decodedJobs[index]
                        .conversionCompletedAt = nil
                    decodedJobs[index]
                        .conversionErrorMessage =
                        """
                        PickPic recovered \(recoveredCount) of \
                        \(decodedJobs[index].photoCount) prepared JPEGs. \
                        Continue the upload to recreate only the \
                        missing photos. Already-uploaded progress was \
                        preserved.
                        """
                    decodedJobs[index]
                        .uploadProgress
                        .currentFilename = nil
                    decodedJobs[index]
                        .uploadProgress
                        .currentStep = nil
                    decodedJobs[index]
                        .uploadProgress
                        .pauseRequested = false
                    decodedJobs[index]
                        .uploadProgress
                        .currentRunStartedAt = nil
                    decodedJobs[index]
                        .uploadProgress
                        .waitingForConnectivitySince = nil
                    decodedJobs[index].updatedAt =
                        recoveryDate
                    changedRecoveredState = true
                    unavailablePreparedBatchCount += 1
                } else if
                    decodedJobs[index].stage == .prepared,
                    decodedJobs[index].photoCount > 0,
                    decodedJobs[index].preparedPhotos
                        .count
                        == decodedJobs[index].photoCount
                {
                    decodedJobs[index].stage =
                        .readyToUpload
                    decodedJobs[index]
                        .conversionProcessedCount =
                            decodedJobs[index].photoCount
                    decodedJobs[index]
                        .conversionCurrentFilename = nil
                    decodedJobs[index]
                        .conversionCompletedAt =
                            decodedJobs[index]
                                .conversionCompletedAt
                            ?? decodedJobs[index]
                                .updatedAt
                    decodedJobs[index]
                        .conversionErrorMessage = nil
                    decodedJobs[index].updatedAt =
                        recoveryDate
                    changedRecoveredState = true
                    fullyRecoveredBatchCount += 1
                }
            }

            decodedJobs.sort { first, second in
                first.createdAt > second.createdAt
            }

            jobs = decodedJobs
            loadErrorMessage = nil

            let unfinishedJobCount = decodedJobs.filter { job in
                job.stage != .completed
            }
            .count

            var recoveryDetails: [String] = []

            if resumedConversionJobCount > 0 {
                recoveryDetails.append(
                    """
                    \(resumedConversionJobCount) interrupted \
                    conversion\(resumedConversionJobCount == 1 ? "" : "s") \
                    will resume from saved JPEGs.
                    """
                )
            }

            if restoredBackgroundTransferCount > 0 {
                recoveryDetails.append(
                    """
                    \(restoredBackgroundTransferCount) iPadOS background \
                    transfer\(restoredBackgroundTransferCount == 1 ? "" : "s") \
                    will be reconnected.
                    """
                )
            }

            if deferredContinuedProcessingCount > 0 {
                recoveryDetails.append(
                    """
                    \(deferredContinuedProcessingCount) continued-processing
                    task\(deferredContinuedProcessingCount == 1 ? "" : "s")
                    can resume from saved progress.
                    """
                )
            }

            if unavailablePreparedBatchCount > 0 {
                recoveryDetails.append(
                    """
                    \(unavailablePreparedBatchCount) \
                    batch\(unavailablePreparedBatchCount == 1 ? "" : "es") \
                    will recreate only missing JPEGs.
                    """
                )
            }

            if fullyRecoveredBatchCount > 0 {
                recoveryDetails.append(
                    """
                    \(fullyRecoveredBatchCount) completed \
                    conversion\(fullyRecoveredBatchCount == 1 ? "" : "s") \
                    \(fullyRecoveredBatchCount == 1 ? "is" : "are") ready to upload.
                    """
                )
            }

            if unfinishedJobCount > 0 {
                let baseMessage: String

                if interruptedJobCount > 0
                    || !recoveryDetails.isEmpty
                {
                    baseMessage =
                        "Interrupted work was restored."
                } else {
                    baseMessage =
                        "Saved work was restored."
                }

                recoveryMessage = ([
                    """
                    PickPic restored \(unfinishedJobCount) unfinished \
                    upload\(unfinishedJobCount == 1 ? "" : "s").
                    """,
                    baseMessage
                ] + recoveryDetails)
                .joined(separator: " ")
            } else {
                recoveryMessage = nil
            }

            if changedRecoveredState {
                try save(decodedJobs)
            }
        } catch {
            jobs = []
            recoveryMessage = nil

            loadErrorMessage =
                """
                The saved upload queue could not be read: \
                \(error.localizedDescription)
                """
        }
    }

    private func save(
        _ jobs: [UploadJob]
    ) throws {
        let directoryURL =
        storageURL.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys
        ]

        let data = try encoder.encode(jobs)

        try data.write(
            to: storageURL,
            options: .atomic
        )
    }

    nonisolated private static func validateRelinkedFolder(
        _ folderURL: URL,
        for job: UploadJob
    ) throws -> RelinkedUploadFolder {
        let accessed = folderURL
            .startAccessingSecurityScopedResource()

        guard accessed else {
            throw UploadFolderRelinkError
                .folderAccessDenied
        }

        defer {
            folderURL
                .stopAccessingSecurityScopedResource()
        }

        let values = try folderURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .nameKey
            ]
        )

        guard values.isDirectory == true else {
            throw UploadFolderRelinkError
                .selectedItemIsNotFolder
        }

        let fileURLs = try FileManager.default
            .contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .fileSizeKey
                ],
                options: [.skipsHiddenFiles]
            )

        var availableFiles: [String: Int64] = [:]

        for fileURL in fileURLs {
            let fileValues = try fileURL
                .resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .fileSizeKey
                    ]
                )

            guard fileValues.isRegularFile == true else {
                continue
            }

            availableFiles[
                fileURL.lastPathComponent
                    .lowercased()
            ] = Int64(fileValues.fileSize ?? 0)
        }

        let missingFilenames = job.photos
            .map(\.filename)
            .filter { filename in
                availableFiles[
                    filename.lowercased()
                ] == nil
            }
            .sorted {
                $0.localizedStandardCompare($1)
                    == .orderedAscending
            }

        guard missingFilenames.isEmpty else {
            throw UploadFolderRelinkError
                .missingSourceFiles(
                    missingFilenames
                )
        }

        let mismatchedFilenames = job.photos
            .filter { photo in
                guard
                    photo.byteSize > 0,
                    let availableByteSize =
                        availableFiles[
                            photo.filename.lowercased()
                        ],
                    availableByteSize > 0
                else {
                    return false
                }

                return availableByteSize
                    != photo.byteSize
            }
            .map(\.filename)
            .sorted {
                $0.localizedStandardCompare($1)
                    == .orderedAscending
            }

        guard mismatchedFilenames.isEmpty else {
            throw UploadFolderRelinkError
                .mismatchedSourceFiles(
                    mismatchedFilenames
                )
        }

        let bookmarkData = try folderURL
            .bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

        return RelinkedUploadFolder(
            name:
                values.name
                ?? folderURL.lastPathComponent,
            bookmarkData: bookmarkData
        )
    }

    private static func makeStorageURL()
    -> URL
    {
        AppStorageService.rootURL
            .appendingPathComponent(
                "upload-queue.json",
                isDirectory: false
            )
    }
}
