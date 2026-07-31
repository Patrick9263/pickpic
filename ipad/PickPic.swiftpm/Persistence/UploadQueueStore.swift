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
        isNetworkRelated: Bool
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

        for job in removedJobs {
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
                let outcome =
                try await client
                    .uploadPreparedPhoto(
                        preparedPhoto,
                        from: fileURL,
                        to: uploadingJob.eventID
                    )

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
            _ = try await client.uploadImageVariants(
                variants,
                sourceKind: .original,
                to: photoID
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
                        friendlyError.isNetworkRelated
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

            case let .variantUploadFailed(
                _,
                reason,
                networkRelated
            ):
                step = .variantUpload
                message = reason
                isNetworkRelated = networkRelated
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
        }

        return UploadFailure(
            sourceFilename: sourceFilename,
            step: step,
            message: message,
            occurredAt: Date(),
            isNetworkRelated: isNetworkRelated
        )
    }

    private func friendlyUploadError(
        _ error: Error,
        sourceFilename: String
    ) -> (
        message: String,
        isNetworkRelated: Bool
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
                false
            )
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return (
                """
                No internet connection. PickPic saved the progress for \
                \(sourceFilename). Reconnect to Wi-Fi and retry.
                """,
                true
            )

        case .networkConnectionLost:
            return (
                """
                The connection was lost while uploading \
                \(sourceFilename). PickPic saved the completed photos; \
                reconnect and retry this one.
                """,
                true
            )

        case .timedOut:
            return (
                """
                Uploading \(sourceFilename) timed out. Check the \
                connection and retry this photo.
                """,
                true
            )

        case .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed:
            return (
                """
                PickPic could not reach the server while uploading \
                \(sourceFilename). Check the connection settings and \
                network, then retry.
                """,
                true
            )

        default:
            return (
                """
                A network error stopped \(sourceFilename): \
                \(urlError.localizedDescription)
                """,
                true
            )
        }
    }

    func runUploadPipeline(
        jobID: UUID,
        using configuration: APIConfigurationStore
    ) async {
        guard !runningPipelineJobIDs.contains(jobID) else {
            return
        }

        runningPipelineJobIDs.insert(jobID)

        defer {
            runningPipelineJobIDs.remove(jobID)
        }

        guard let startingStage = stage(for: jobID) else {
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

        case .prepared,
                .readyToUpload:
            break

        case .preparing,
                .converting,
                .uploading,
                .completed:
            return
        }

        if stage(for: jobID) == .prepared {
            await convertAllPhotos(jobID: jobID)
            guard !Task.isCancelled else {
                return
            }
            guard stage(for: jobID) == .readyToUpload else {
                return
            }
        }

        if stage(for: jobID) == .readyToUpload {
            await uploadAllPhotos(
                jobID: jobID,
                using: configuration
            )
        }
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
            let recoveryDate = Date()

            for index in decodedJobs.indices {
                let originalStage =
                    decodedJobs[index].stage

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
                        """
                        Uploading was interrupted. \
                        Resume the remaining photos.
                        """
                    decodedJobs[index]
                        .uploadProgress
                        .pauseRequested = false
                    decodedJobs[index]
                        .uploadProgress
                        .pausedAt = nil
                    decodedJobs[index]
                        .uploadProgress
                        .currentRunStartedAt = nil
                    decodedJobs[index].updatedAt =
                        recoveryDate
                    changedRecoveredState = true
                    interruptedJobCount += 1

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
