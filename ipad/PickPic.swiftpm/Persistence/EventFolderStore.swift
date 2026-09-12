import Combine
import Foundation

enum EventFolderStoreError: LocalizedError {
    case folderAccessDenied
    case selectedItemIsNotFolder
    case storageNotIntact

    var errorDescription: String? {
        switch self {
        case .folderAccessDenied:
            return """
            PickPic could not access the selected event folder.
            """
            
        case .selectedItemIsNotFolder:
            return "The selected item is not a folder."

        case .storageNotIntact:
            return """
            PickPic could not read every saved event folder, so it will \
            not write over the file that holds them. The saved folders \
            are still on disk, and a later version of the app may be \
            able to read them.
            """
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
    
    /*
     * False once load() has seen anything it could not decode -- a
     * malformed file, or an individual entry it had to skip.
     *
     * This is the load-bearing half of the fix for issue #234. load() used
     * to answer a decode failure with `references = [:]`, and the next
     * save() then wrote that empty map over the file, destroying every
     * security-scoped bookmark on the device at once. Bookmarks cannot be
     * regenerated from anything the app holds: recovery is re-picking
     * every event folder by hand through the document picker.
     *
     * So a store that could not read its file completely goes read-only.
     * Refusing to write is loud -- every call site already surfaces the
     * throw -- and, unlike the old wipe, it is reversible: the bytes stay
     * on disk, so a build with a corrected decoder can still recover them.
     * Losing folder links for one session is worth far less than losing
     * every link permanently.
     */
    private var isStorageIntact = true

    convenience init() {
        self.init(storageURL: Self.makeStorageURL())
    }

    init(
        storageURL: URL
    ) {
        self.storageURL = storageURL
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
            
            let result = try Self.decodeReferences(
                from: data
            )

            references = result.references

            guard result.skippedCount > 0 else {
                loadErrorMessage = nil
                return
            }

            isStorageIntact = false

            let noun =
            result.skippedCount == 1
            ? "folder"
            : "folders"

            loadErrorMessage =
                """
                \(result.skippedCount) saved event \(noun) could not be \
                read. The rest still work, but PickPic will not save \
                changes to event folders until the whole file can be \
                read, so nothing unreadable gets overwritten.
                """
        } catch {
            /*
             * Deliberately leaves `references` alone rather than emptying
             * it. That, plus the isStorageIntact guard in persist(), is
             * what stops a decode failure from becoming a wipe -- see the
             * comment on isStorageIntact.
             */
            isStorageIntact = false

            loadErrorMessage =
                """
                Saved event folders could not be read: \
                \(error.localizedDescription)
                """
        }
    }

    /*
     * Decodes each entry on its own so one unreadable reference costs only
     * itself. The strict decode is tried first because it is the whole
     * story in every normal case; the per-entry pass runs only when
     * something is already wrong.
     *
     * A caller that sees skippedCount > 0 must treat the file as not
     * intact. Salvaging keeps the readable folders usable; it is never a
     * decision that the skipped ones are expendable -- those stay on disk.
     */
    static func decodeReferences(
        from data: Data
    ) throws -> (
        references: [String: EventFolderReference],
        skippedCount: Int
    ) {
        let decoder = JSONDecoder()

        if let strict = try? decoder.decode(
            [String: EventFolderReference].self,
            from: data
        ) {
            return (strict, 0)
        }

        let salvaged = try decoder.decode(
            [String: SalvagedReference].self,
            from: data
        )

        var references:
        [String: EventFolderReference] = [:]
        var skippedCount = 0

        for (eventID, entry) in salvaged {
            guard let reference = entry.reference else {
                skippedCount += 1
                continue
            }

            references[eventID] = reference
        }

        return (references, skippedCount)
    }

    private struct SalvagedReference: Decodable {
        let reference: EventFolderReference?

        init(
            from decoder: Decoder
        ) throws {
            reference = try? EventFolderReference(
                from: decoder
            )
        }
    }

    private func persist(
        _ references: [String: EventFolderReference]
    ) throws {
        guard isStorageIntact else {
            throw EventFolderStoreError.storageNotIntact
        }

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
