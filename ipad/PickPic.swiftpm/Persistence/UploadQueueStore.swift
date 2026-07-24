import Combine
import Foundation

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
        
        do {
            try updateJob(jobID) { job in
                job.stage = .converting
                job.preparedPhotos = []
                job.conversionProcessedCount = 0
                job.conversionCurrentFilename = nil
                job.conversionStartedAt = startedAt
                job.conversionCompletedAt = nil
                job.conversionErrorMessage = nil
                job.uploadProgress = .empty
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
                
                switch outcome {
                case .uploaded:
                    isDuplicate = false
                    
                case .duplicate:
                    isDuplicate = true
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
            
            var recoveredInterruptedJob = false
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
                    recoveredInterruptedJob = true
                    
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
                    recoveredInterruptedJob = true
                    
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
                    decodedJobs[index].updatedAt =
                    Date()
                    recoveredInterruptedJob = true
                    
                case .queued,
                        .prepared,
                        .readyToUpload,
                        .completed,
                        .failed:
                    break
                }
            }
            
            decodedJobs.sort { first, second in
                first.createdAt > second.createdAt
            }
            
            jobs = decodedJobs
            loadErrorMessage = nil
            
            if recoveredInterruptedJob {
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
