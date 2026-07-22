import Combine
import Foundation
import UniformTypeIdentifiers

private struct FolderScanResult: Sendable {
    let folderName: String
    let photos: [SourcePhoto]
}

private enum FolderScanError: LocalizedError {
    case selectedItemIsNotFolder
    
    var errorDescription: String? {
        switch self {
        case .selectedItemIsNotFolder:
            return "The selected item is not a folder."
        }
    }
}

@MainActor
final class PhotoImportViewModel: ObservableObject {
    @Published private(set) var folderName: String?
    @Published private(set) var photos: [SourcePhoto] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?
    
    var totalBytes: Int64 {
        photos.reduce(0) { partialResult, photo in
            partialResult + photo.byteSize
        }
    }
    
    func scan(folderURL: URL) async {
        guard !isScanning else {
            return
        }
        
        isScanning = true
        errorMessage = nil
        
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
            photos = result.photos
        } catch {
            folderName = nil
            photos = []
            errorMessage = error.localizedDescription
        }
    }
    
    func showError(_ error: Error) {
        errorMessage = error.localizedDescription
    }
    
    func clearError() {
        errorMessage = nil
    }
    
    nonisolated private static func scanFolder(
        _ folderURL: URL
    ) throws -> FolderScanResult {
        let accessed =
        folderURL.startAccessingSecurityScopedResource()
        
        defer {
            if accessed {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let folderValues = try folderURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .nameKey
            ]
        )
        
        guard folderValues.isDirectory == true else {
            throw FolderScanError.selectedItemIsNotFolder
        }
        
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentTypeKey
        ]
        
        let fileURLs = try FileManager.default
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
        
        let photos: [SourcePhoto] = try fileURLs.compactMap {
            (fileURL: URL) throws -> SourcePhoto? in
            
            let values = try fileURL.resourceValues(
                forKeys: resourceKeys
            )
            
            guard values.isRegularFile == true else {
                return nil
            }
            
            let fileExtension =
            fileURL.pathExtension.lowercased()
            
            let kind: SourcePhoto.Kind?
            
            if values.contentType?.conforms(to: .rawImage) == true
                || rawExtensions.contains(fileExtension) {
                kind = .raw
            } else if values.contentType?.conforms(to: .jpeg) == true
                        || jpegExtensions.contains(fileExtension) {
                kind = .jpeg
            } else {
                kind = nil
            }
            
            guard let kind else {
                return nil
            }
            
            return SourcePhoto(
                filename: fileURL.lastPathComponent,
                byteSize: Int64(values.fileSize ?? 0),
                kind: kind
            )
        }
        
        let sortedPhotos: [SourcePhoto] = photos.sorted {
            (first: SourcePhoto, second: SourcePhoto) in
            
            first.filename.localizedStandardCompare(
                second.filename
            ) == .orderedAscending
        }
        
        return FolderScanResult(
            folderName:
                folderValues.name
            ?? folderURL.lastPathComponent,
            photos: sortedPhotos
        )
    }
}
