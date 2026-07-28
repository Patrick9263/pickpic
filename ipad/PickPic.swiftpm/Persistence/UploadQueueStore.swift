import Combine
import Foundation

private enum UploadQueuePipelineError:
    LocalizedError
{
    case originalOptimizationFailed(
        filename: String,
        reason: String
    )
    
    var errorDescription: String? {
        switch self {
        case let .originalOptimizationFailed(
            filename,
            reason
        ):
            return """
            \(filename) uploaded, but its optimized web versions could \
            not be created. Resume the upload to retry without \
            duplicating the full photo. \(reason)
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
        
        do {
            try updateJob(jobID) { job in
                job.stage = .converting
                job.preparedPhotos = []
                job.conversionProcessedCount = 0
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
                    errorMessage: nil
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
            try await Task.detached(
                priority: .userInitiated
            ) {
                try ImageConversionService
                    .resetPreparedPhotos(
                        for: jobID
                    )
            }.value
            
            for (
                index,
                sourcePhoto
            ) in convertingJob.photos.enumerated() {
                try Task.checkCancellation()
                
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
            let conversionError =
            error.localizedDescription
            
            try? await Task.detached {
                try ImageConversionService
                    .removePreparedPhotos(
                        for: jobID
                    )
            }.value
            
            do {
                try updateJob(jobID) { job in
                    job.stage = .prepared
                    job.preparedPhotos = []
                    job.conversionProcessedCount =
                    0
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
        APIConfigurationStore
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
                    
                    job.updatedAt = Date()
                }
            } catch {
                loadErrorMessage =
                error.localizedDescription
            }
            
            return
        }
        
        let client: APIClient
        
        do {
            client = try configuration.makeClient()
        } catch {
            do {
                try updateJob(jobID) { job in
                    job.uploadProgress.errorMessage =
                    error.localizedDescription
                    
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
        
        do {
            try updateJob(jobID) { job in
                job.stage = .uploading
                
                job.uploadProgress.startedAt =
                startedAt
                
                job.uploadProgress.completedAt =
                nil
                
                job.uploadProgress.currentFilename =
                nil
                
                job.uploadProgress.errorMessage =
                nil
                
                job.updatedAt = Date()
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
        
        for preparedPhoto in uploadingJob.preparedPhotos {
            if Task.isCancelled {
                do {
                    try updateJob(jobID) { job in
                        job.stage = .readyToUpload
                        job.uploadProgress.currentFilename = nil
                        job.uploadProgress.errorMessage =
                        "Uploading was cancelled. Resume the remaining photos."
                        job.updatedAt = Date()
                    }
                } catch {
                    loadErrorMessage =
                """
                Uploading was cancelled, but the queue \
                could not be updated: \
                \(error.localizedDescription)
                """
                }
                
                return
            }
            
            if completedFilenames.contains(
                preparedPhoto.sourceFilename
            ) {
                continue
            }
            
            do {
                try updateJob(jobID) { job in
                    job.uploadProgress
                        .currentFilename =
                    preparedPhoto.sourceFilename
                    
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
                    do {
                        try await uploadOriginalVariants(
                            from: fileURL,
                            photoID: photoID,
                            jobID: jobID,
                            using: client
                        )
                    } catch {
                        throw UploadQueuePipelineError
                            .originalOptimizationFailed(
                                filename:
                                    preparedPhoto
                                        .sourceFilename,
                                reason:
                                    error.localizedDescription
                            )
                    }
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
                    
                    job.uploadProgress
                        .currentFilename = nil
                    
                    job.uploadProgress
                        .errorMessage = nil
                    
                    job.updatedAt = Date()
                }
            } catch {
                let uploadError =
                error.localizedDescription
                
                do {
                    try updateJob(jobID) { job in
                        job.stage = .readyToUpload
                        
                        job.uploadProgress
                            .currentFilename = nil
                        
                        job.uploadProgress
                            .errorMessage =
                        uploadError
                        
                        job.updatedAt = Date()
                    }
                } catch {
                    loadErrorMessage =
                    """
                    Uploading failed, and the queue \
                    could not be saved: \
                    \(error.localizedDescription)
                    """
                }
                
                return
            }
        }
        
        let completedAt = Date()
        
        do {
            try updateJob(jobID) { job in
                job.stage = .completed
                
                job.uploadProgress
                    .currentFilename = nil
                
                job.uploadProgress
                    .completedAt = completedAt
                
                job.uploadProgress
                    .errorMessage = nil
                
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
        
        try? ImageConversionService
            .removePreparedPhotos(
                for: jobID
            )
    }
    
    private func uploadOriginalVariants(
        from sourceURL: URL,
        photoID: String,
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
        
        let variants =
        try await Task.detached(
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
        
        _ = try await client.uploadImageVariants(
            variants,
            sourceKind: .original,
            to: photoID
        )
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
            var unavailablePreparedBatchCount = 0
            var interruptedConversionJobIDs:
            [UUID] = []
            
            for index in decodedJobs.indices {
                switch decodedJobs[index].stage {
                case .preparing:
                    decodedJobs[index].stage = .failed
                    decodedJobs[index].errorMessage =
                        """
                        Folder preparation was interrupted. \
                        Try the job again.
                        """
                    decodedJobs[index].updatedAt = Date()
                    changedRecoveredState = true
                    interruptedJobCount += 1
                    
                case .converting:
                    interruptedConversionJobIDs.append(
                        decodedJobs[index].id
                    )
                    decodedJobs[index].stage = .prepared
                    decodedJobs[index].preparedPhotos = []
                    decodedJobs[index]
                        .conversionProcessedCount = 0
                    decodedJobs[index]
                        .conversionCurrentFilename = nil
                    decodedJobs[index]
                        .conversionCompletedAt = nil
                    decodedJobs[index]
                        .conversionErrorMessage =
                            """
                            Batch conversion was interrupted. \
                            Start the conversion again.
                            """
                    decodedJobs[index].updatedAt = Date()
                    changedRecoveredState = true
                    interruptedJobCount += 1
                    
                case .uploading:
                    decodedJobs[index].stage =
                        .readyToUpload
                    decodedJobs[index]
                        .uploadProgress
                        .currentFilename = nil
                    decodedJobs[index]
                        .uploadProgress
                        .errorMessage =
                        """
                        Uploading was interrupted. \
                        Resume the remaining photos.
                        """
                    decodedJobs[index].updatedAt = Date()
                    changedRecoveredState = true
                    interruptedJobCount += 1
                    
                case .queued,
                        .prepared,
                        .readyToUpload,
                        .completed,
                        .failed:
                    break
                }
                
                if decodedJobs[index].stage == .readyToUpload,
                    !ImageConversionService
                        .preparedBatchIsAvailable(
                            for: decodedJobs[index]
                        )
                {
                    decodedJobs[index].stage = .prepared
                    decodedJobs[index].preparedPhotos = []
                    decodedJobs[index]
                        .conversionProcessedCount = 0
                    decodedJobs[index]
                        .conversionCurrentFilename = nil
                    decodedJobs[index]
                        .conversionCompletedAt = nil
                    decodedJobs[index]
                        .conversionErrorMessage =
                        """
                        The prepared JPEGs were not available after \
                        relaunching PickPic. Convert the batch again. \
                        Already-uploaded progress was preserved.
                        """
                    decodedJobs[index]
                        .uploadProgress
                        .currentFilename = nil
                    decodedJobs[index].updatedAt = Date()
                    changedRecoveredState = true
                    unavailablePreparedBatchCount += 1
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
            
            if unavailablePreparedBatchCount > 0 {
                recoveryMessage =
                """
                PickPic restored \(unfinishedJobCount) unfinished \
                upload\(unfinishedJobCount == 1 ? "" : "s"). \
                \(unavailablePreparedBatchCount) batch\(unavailablePreparedBatchCount == 1 ? "" : "es") \
                must be converted again; completed upload progress \
                was preserved.
                """
            } else if interruptedJobCount > 0 {
                recoveryMessage =
                """
                PickPic restored \(unfinishedJobCount) unfinished \
                upload\(unfinishedJobCount == 1 ? "" : "s"). \
                Interrupted work is ready to continue.
                """
            } else if unfinishedJobCount > 0 {
                recoveryMessage =
                """
                PickPic restored \(unfinishedJobCount) saved \
                upload\(unfinishedJobCount == 1 ? "" : "s") \
                from the previous session.
                """
            } else {
                recoveryMessage = nil
            }
            
            if changedRecoveredState {
                try save(decodedJobs)
            }
            
            for jobID in interruptedConversionJobIDs {
                try? ImageConversionService
                    .removePreparedPhotos(
                        for: jobID
                    )
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
                    .isRegularFileKey
                ],
                options: [.skipsHiddenFiles]
            )

        var availableFilenames: Set<String> = []

        for fileURL in fileURLs {
            let fileValues = try fileURL
                .resourceValues(
                    forKeys: [.isRegularFileKey]
                )

            guard fileValues.isRegularFile == true else {
                continue
            }

            availableFilenames.insert(
                fileURL.lastPathComponent
                    .lowercased()
            )
        }

        let missingFilenames = job.photos
            .map(\.filename)
            .filter { filename in
                !availableFilenames.contains(
                    filename.lowercased()
                )
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
