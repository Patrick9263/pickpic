import Combine
import Foundation
import UniformTypeIdentifiers

private struct FolderScanResult: Sendable {
    let folderName: String
    let folderBookmarkData: Data
    let photos: [SourcePhoto]
}

private enum FolderScanError: LocalizedError {
    case selectedItemIsNotFolder
    case noFolderSelected
    case noSupportedPhotos
    
    var errorDescription: String? {
        switch self {
        case .selectedItemIsNotFolder:
            return "The selected item is not a folder."
            
        case .noFolderSelected:
            return "Choose an event folder first."
            
        case .noSupportedPhotos:
            return """
            The selected folder does not contain any \
            supported photos.
            """
        }
    }
}

@MainActor
final class PhotoImportViewModel: ObservableObject {
    @Published private(set)
    var folderName: String?
    
    @Published private(set)
    var photos: [SourcePhoto] = []
    
    @Published private(set)
    var isScanning = false
    
    @Published private(set)
    var errorMessage: String?
    
    private var folderBookmarkData: Data?
    
    var totalBytes: Int64 {
        photos.reduce(0) { result, photo in
            result + photo.byteSize
        }
    }
    
    func scan(
        folderURL: URL
    ) async {
        guard !isScanning else {
            return
        }
        
        isScanning = true
        errorMessage = nil
        folderBookmarkData = nil
        
        defer {
            isScanning = false
        }
        
        do {
            let result = try await Task.detached(
                priority: .userInitiated
            ) {
                try Self.scanFolder(folderURL)
            }.value
            
            folderName = result.folderName
            folderBookmarkData =
            result.folderBookmarkData
            photos = result.photos
        } catch {
            folderName = nil
            folderBookmarkData = nil
            photos = []
            errorMessage = error.localizedDescription
        }
    }
    
    func makeUploadJob(
        for event: PickPicEvent
    ) throws -> UploadJob {
        guard
            let folderName,
            let folderBookmarkData
        else {
            throw FolderScanError.noFolderSelected
        }
        
        guard !photos.isEmpty else {
            throw FolderScanError.noSupportedPhotos
        }
        
        let now = Date()
        
        return UploadJob(
            id: UUID(),
            eventID: event.id,
            eventTitle: event.title,
            folderName: folderName,
            folderBookmarkData:
                folderBookmarkData,
            photos: photos,
            stage: .queued,
            createdAt: now,
            updatedAt: now
        )
    }
    
    func showError(
        _ error: Error
    ) {
        errorMessage = error.localizedDescription
    }
    
    func clearError() {
        errorMessage = nil
    }
    
    nonisolated private static func scanFolder(
        _ folderURL: URL
    ) throws -> FolderScanResult {
        let accessed =
        folderURL
            .startAccessingSecurityScopedResource()
        
        guard accessed else {
            throw CocoaError(
                .fileReadNoPermission
            )
        }
        
        defer {
            folderURL
                .stopAccessingSecurityScopedResource()
        }
        
        let folderValues =
        try folderURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .nameKey
            ]
        )
        
        guard
            folderValues.isDirectory == true
        else {
            throw FolderScanError
                .selectedItemIsNotFolder
        }
        
        let bookmarkData =
        try folderURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentTypeKey
        ]
        
        let fileURLs =
        try FileManager.default
            .contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys:
                    Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
        
        let rawExtensions: Set<String> = [
            "arw",
            "cr2",
            "cr3",
            "dng",
            "nef",
            "nrw",
            "orf",
            "pef",
            "raf",
            "rw2",
            "srw"
        ]
        
        let jpegExtensions: Set<String> = [
            "jpg",
            "jpeg"
        ]
        
        let photos: [SourcePhoto] =
        try fileURLs.compactMap {
            (
                fileURL: URL
            ) throws -> SourcePhoto? in
            
            let values =
            try fileURL.resourceValues(
                forKeys: resourceKeys
            )
            
            guard
                values.isRegularFile == true
            else {
                return nil
            }
            
            let fileExtension =
            fileURL
                .pathExtension
                .lowercased()
            
            let kind: SourcePhoto.Kind?
            
            if values.contentType?.conforms(
                to: .rawImage
            ) == true
                || rawExtensions.contains(
                    fileExtension
                ) {
                kind = .raw
            } else if
                values.contentType?.conforms(
                    to: .jpeg
                ) == true
                    || jpegExtensions.contains(
                        fileExtension
                    ) {
                kind = .jpeg
            } else {
                kind = nil
            }
            
            guard let kind else {
                return nil
            }
            
            return SourcePhoto(
                filename:
                    fileURL.lastPathComponent,
                byteSize:
                    Int64(values.fileSize ?? 0),
                kind: kind
            )
        }
        
        let sortedPhotos: [SourcePhoto] =
        photos.sorted {
            (
                first: SourcePhoto,
                second: SourcePhoto
            ) in
            
            first.filename
                .localizedStandardCompare(
                    second.filename
                )
            == .orderedAscending
        }
        
        return FolderScanResult(
            folderName:
                folderValues.name
            ?? folderURL.lastPathComponent,
            folderBookmarkData: bookmarkData,
            photos: sortedPhotos
        )
    }
}
