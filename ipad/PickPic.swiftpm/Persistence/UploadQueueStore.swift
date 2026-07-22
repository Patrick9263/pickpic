import Combine
import Foundation

@MainActor
final class UploadQueueStore: ObservableObject {
    @Published private(set) var jobs: [UploadJob] = []
    
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
            
            let decodedJobs = try JSONDecoder().decode(
                [UploadJob].self,
                from: data
            )
            
            jobs = decodedJobs.sorted {
                first,
                second in
                
                first.createdAt > second.createdAt
            }
            
            loadErrorMessage = nil
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
