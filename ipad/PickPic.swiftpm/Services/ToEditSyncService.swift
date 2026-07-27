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

enum ToEditSyncService {
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
