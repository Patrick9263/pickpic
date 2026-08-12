import Foundation

struct ToEditSyncResult:
    Hashable,
    Sendable
{
    let likedPhotoCount: Int
    let copiedPhotoCount: Int
    let alreadyPresentCount: Int
    
    let syncedFilenames: Set<String>
    let missingFilenames: [String]
    
    let syncedAt: Date
}

enum ToEditSyncError: LocalizedError {
    case sourceFolderUnavailable
    case invalidSourceFilename(String)
    case destinationIsDirectory(String)
    
    var errorDescription: String? {
        switch self {
        case .sourceFolderUnavailable:
            return """
            PickPic could not access the saved event folder. \
            Select the folder again.
            """
            
        case let .invalidSourceFilename(filename):
            return """
            The server returned an unsafe source filename: \
            \(filename).
            """
            
        case let .destinationIsDirectory(filename):
            return """
            An item named \(filename) already exists in \
            To Edit, but it is not a file.
            """
        }
    }
}

enum ToEditFileError: LocalizedError {
    case folderUnavailable
    case notSyncedYet(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable:
            return """
            PickPic could not access the saved event folder. \
            Select the folder again.
            """

        case let .notSyncedYet(filename):
            return """
            \(filename) is not in To Edit yet. Sync requested \
            photos first.
            """
        }
    }
}

enum ToEditSyncService {
    /*
     * Stages a liked photo's RAW inside the app container and returns
     * that copy, for handing to an external editor.
     *
     * The copy is the point. Sharing the file straight out of To Edit
     * means sharing through a security-scoped folder bookmark, and the
     * receiving app reads the file *after* the share sheet closes — by
     * which time the scope is gone and it silently receives nothing.
     * A copy inside the container has no such lifetime.
     *
     * Stale copies are swept at launch by AppStorageService.cleanup,
     * never here, so a handoff still in flight is never pulled away.
     */
    static func stageFileForEditing(
        named filename: String,
        reference: EventFolderReference
    ) throws -> URL {
        let resolved = try FolderBookmarkService.resolve(
            reference.bookmarkData
        )

        let eventFolderURL = resolved.url

        guard
            eventFolderURL
                .startAccessingSecurityScopedResource()
        else {
            throw ToEditFileError.folderUnavailable
        }

        defer {
            eventFolderURL
                .stopAccessingSecurityScopedResource()
        }

        let sourceURL =
        eventFolderURL
            .appending(
                path: UploadPreparationService
                    .toEditFolderName
            )
            .appending(path: filename)

        let fileManager = FileManager.default

        guard
            fileManager.fileExists(
                atPath: sourceURL.path
            )
        else {
            throw ToEditFileError
                .notSyncedYet(filename)
        }

        let stagingURL =
        AppStorageService.editHandoffStagingURL

        /*
         * Only ever one staged RAW at a time. Clearing on the way in
         * keeps a large file from lingering until the next launch.
         */
        if fileManager.fileExists(
            atPath: stagingURL.path
        ) {
            try fileManager.removeItem(
                at: stagingURL
            )
        }

        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true
        )

        let sourceByteSize =
        (try? sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize)
            .map(Int64.init)
        ?? 0

        try AppStorageService
            .ensureEditHandoffCapacity(
                fileByteSize: sourceByteSize
            )

        let stagedURL =
        stagingURL.appending(path: filename)

        try fileManager.copyItem(
            at: sourceURL,
            to: stagedURL
        )

        return stagedURL
    }

    static func sync(
        reference: EventFolderReference,
        photos: [ServerPhotoRecord]
    ) throws -> ToEditSyncResult {
        let resolved = try FolderBookmarkService.resolve(
            reference.bookmarkData
        )
        
        let eventFolderURL = resolved.url
        
        let accessed =
        eventFolderURL
            .startAccessingSecurityScopedResource()
        
        guard accessed else {
            throw ToEditSyncError
                .sourceFolderUnavailable
        }
        
        defer {
            eventFolderURL
                .stopAccessingSecurityScopedResource()
        }
        
        var isDirectory: ObjCBool = false
        
        guard
            FileManager.default.fileExists(
                atPath: eventFolderURL.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            throw ToEditSyncError
                .sourceFolderUnavailable
        }
        
        let toEditURL =
        eventFolderURL.appendingPathComponent(
            UploadPreparationService
                .toEditFolderName,
            isDirectory: true
        )
        
        try FileManager.default.createDirectory(
            at: toEditURL,
            withIntermediateDirectories: true
        )
        
        let likedPhotos = photos
            .filter { photo in
                photo.heartCount > 0
            }
            .sorted { first, second in
                first.originalFilename
                    .localizedStandardCompare(
                        second.originalFilename
                    )
                == .orderedAscending
            }
        
        var copiedPhotoCount = 0
        var alreadyPresentCount = 0
        var syncedFilenames: Set<String> = []
        var missingFilenames: [String] = []
        
        for photo in likedPhotos {
            let filename = photo.originalFilename
            
            let safeFilename =
            (filename as NSString)
                .lastPathComponent
            
            guard
                !filename.isEmpty,
                filename == safeFilename,
                filename != ".",
                filename != ".."
            else {
                throw ToEditSyncError
                    .invalidSourceFilename(filename)
            }
            
            let sourceURL =
            eventFolderURL.appendingPathComponent(
                filename,
                isDirectory: false
            )
            
            var sourceIsDirectory: ObjCBool = false
            
            guard
                FileManager.default.fileExists(
                    atPath: sourceURL.path,
                    isDirectory: &sourceIsDirectory
                ),
                !sourceIsDirectory.boolValue
            else {
                missingFilenames.append(filename)
                continue
            }
            
            let destinationURL =
            toEditURL.appendingPathComponent(
                filename,
                isDirectory: false
            )
            
            var destinationIsDirectory:
            ObjCBool = false
            
            if FileManager.default.fileExists(
                atPath: destinationURL.path,
                isDirectory:
                    &destinationIsDirectory
            ) {
                guard
                    !destinationIsDirectory.boolValue
                else {
                    throw ToEditSyncError
                        .destinationIsDirectory(
                            filename
                        )
                }
                
                alreadyPresentCount += 1
                syncedFilenames.insert(filename)
                continue
            }
            
            try FileManager.default.copyItem(
                at: sourceURL,
                to: destinationURL
            )
            
            copiedPhotoCount += 1
            syncedFilenames.insert(filename)
        }
        
        return ToEditSyncResult(
            likedPhotoCount: likedPhotos.count,
            copiedPhotoCount: copiedPhotoCount,
            alreadyPresentCount: alreadyPresentCount,
            syncedFilenames: syncedFilenames,
            missingFilenames: missingFilenames,
            syncedAt: Date()
        )
    }
}

struct RequestedPhotoSyncResult: Sendable {
    let photos: [ServerPhotoRecord]
    let fileResult: ToEditSyncResult
    let markedEditingCount: Int
    let workflowUpdateFailures: [String]
}

@MainActor
enum RequestedPhotoSyncService {
    private static var activeEventIDs: Set<String> = []

    static func sync(
        eventID: String,
        reference: EventFolderReference,
        using client: APIClient
    ) async throws -> RequestedPhotoSyncResult? {
        guard activeEventIDs.insert(eventID).inserted else {
            return nil
        }

        defer {
            activeEventIDs.remove(eventID)
        }

        let currentPhotos =
        try await client.fetchEventPhotos(
            eventID: eventID
        )

        let fileResult =
        try await Task.detached(
            priority: .userInitiated
        ) {
            try ToEditSyncService.sync(
                reference: reference,
                photos: currentPhotos
            )
        }
        .value

        let photosToMarkEditing =
        currentPhotos.filter { photo in
            photo.heartCount > 0
            && fileResult.syncedFilenames.contains(
                photo.originalFilename
            )
            && photo.workflowStatus == .idle
        }

        var markedEditingCount = 0
        var workflowUpdateFailures: [String] = []

        for photo in photosToMarkEditing {
            do {
                _ = try await client
                    .setPhotoWorkflowStatus(
                        .editing,
                        for: photo.id
                    )

                markedEditingCount += 1
            } catch {
                workflowUpdateFailures.append(
                    photo.originalFilename
                )
            }
        }

        let refreshedPhotos: [ServerPhotoRecord]

        if photosToMarkEditing.isEmpty {
            refreshedPhotos = currentPhotos
        } else {
            refreshedPhotos =
            try await client.fetchEventPhotos(
                eventID: eventID
            )
        }

        return RequestedPhotoSyncResult(
            photos: refreshedPhotos,
            fileResult: fileResult,
            markedEditingCount: markedEditingCount,
            workflowUpdateFailures:
                workflowUpdateFailures
        )
    }
}
