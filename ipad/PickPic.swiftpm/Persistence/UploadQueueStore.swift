import Combine
import Foundation

@MainActor
final class UploadQueueStore: ObservableObject {
    @Published private(set)
    var jobs: [UploadJob] = []
    
    @Published private(set)
    var loadErrorMessage: String?
    
    private let storageURL: URL
    
    init() {
        storageURL = Self.makeStorageURL()
        load()
    }
    
    func jobs(
        for eventID: String
    ) -> [UploadJob] {
        jobs.filter { job in
            job.eventID == eventID
        }
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
        let updatedJobs = jobs.filter { job in
            !jobIDs.contains(job.id)
        }
        
        try save(updatedJobs)
        
        jobs = updatedJobs
        loadErrorMessage = nil
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
            
            for index in decodedJobs.indices {
                switch decodedJobs[index].stage {
                case .preparing,
                        .converting,
                        .uploading:
                    decodedJobs[index].stage = .failed
                    decodedJobs[index].errorMessage =
                        """
                        Processing was interrupted. \
                        Try the job again.
                        """
                    decodedJobs[index].updatedAt =
                    Date()
                    
                    recoveredInterruptedJob = true
                    
                case .queued,
                        .prepared,
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
    
    private static func makeStorageURL() -> URL {
        let fileManager = FileManager.default
        
        let baseURL =
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        ?? fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        
        return baseURL
            .appendingPathComponent(
                "PickPic",
                isDirectory: true
            )
            .appendingPathComponent(
                "upload-queue.json"
            )
    }
}
