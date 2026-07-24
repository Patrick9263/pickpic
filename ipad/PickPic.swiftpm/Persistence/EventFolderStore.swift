import Combine
import Foundation

enum EventFolderStoreError: LocalizedError {
    case folderAccessDenied
    case selectedItemIsNotFolder
    
    var errorDescription: String? {
        switch self {
        case .folderAccessDenied:
            return """
            PickPic could not access the selected event folder.
            """
            
        case .selectedItemIsNotFolder:
            return "The selected item is not a folder."
        }
    }
}

@MainActor
final class EventFolderStore: ObservableObject {
    @Published private(set)
    var references: [String: EventFolderReference] = [:]
    
    @Published private(set)
    var loadErrorMessage: String?
    
    private let storageURL: URL
    
    init() {
        storageURL = Self.makeStorageURL()
        load()
    }
    
    func reference(
        for eventID: String
    ) -> EventFolderReference? {
        references[eventID]
    }
    
    func save(
        job: UploadJob
    ) throws {
        let reference = EventFolderReference(
            eventID: job.eventID,
            folderName: job.folderName,
            bookmarkData: job.folderBookmarkData,
            updatedAt: Date()
        )
        
        try save(reference)
    }
    
    func saveFolder(
        _ folderURL: URL,
        for event: PickPicEvent
    ) throws {
        let accessed =
        folderURL.startAccessingSecurityScopedResource()
        
        guard accessed else {
            throw EventFolderStoreError.folderAccessDenied
        }
        
        defer {
            folderURL.stopAccessingSecurityScopedResource()
        }
        
        let values = try folderURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .nameKey
            ]
        )
        
        guard values.isDirectory == true else {
            throw EventFolderStoreError
                .selectedItemIsNotFolder
        }
        
        let bookmarkData = try folderURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        let reference = EventFolderReference(
            eventID: event.id,
            folderName:
                values.name
            ?? folderURL.lastPathComponent,
            bookmarkData: bookmarkData,
            updatedAt: Date()
        )
        
        try save(reference)
    }
    
    func removeReference(
        for eventID: String
    ) throws {
        var updatedReferences = references
        updatedReferences[eventID] = nil
        
        try persist(updatedReferences)
        
        references = updatedReferences
        loadErrorMessage = nil
    }
    
    private func save(
        _ reference: EventFolderReference
    ) throws {
        var updatedReferences = references
        updatedReferences[reference.eventID] = reference
        
        try persist(updatedReferences)
        
        references = updatedReferences
        loadErrorMessage = nil
    }
    
    private func load() {
        guard FileManager.default.fileExists(
            atPath: storageURL.path
        ) else {
            references = [:]
            return
        }
        
        do {
            let data = try Data(
                contentsOf: storageURL
            )
            
            references = try JSONDecoder().decode(
                [String: EventFolderReference].self,
                from: data
            )
            
            loadErrorMessage = nil
        } catch {
            references = [:]
            
            loadErrorMessage =
                """
                Saved event folders could not be read: \
                \(error.localizedDescription)
                """
        }
    }
    
    private func persist(
        _ references: [String: EventFolderReference]
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
        
        let data = try encoder.encode(references)
        
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
                "event-folders.json",
                isDirectory: false
            )
    }
}
