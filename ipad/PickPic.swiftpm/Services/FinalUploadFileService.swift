import Foundation

struct StagedFinalUpload: Sendable {
    let fileURL: URL
    let filename: String
    let sha256: String
    let byteSize: Int64
    let variants: GeneratedFinalVariants
}

enum FinalUploadFileError: LocalizedError {
    case eventFolderUnavailable
    case invalidFilename(String)
    case fileMissing(String)
    case fileTooLarge(String, Int64)
    
    var errorDescription: String? {
        switch self {
        case .eventFolderUnavailable:
            return """
            PickPic could not access the saved event folder.
            """
            
        case let .invalidFilename(filename):
            return """
            The edited filename is invalid: \(filename).
            """
            
        case let .fileMissing(filename):
            return """
            \(filename) could not be found in Edited.
            """
            
        case let .fileTooLarge(filename, byteSize):
            let formattedSize =
            ByteCountFormatter.string(
                fromByteCount: byteSize,
                countStyle: .file
            )
            
            return """
            \(filename) is \(formattedSize). Final JPEGs \
            must be 50 MB or smaller.
            """
        }
    }
}

enum FinalUploadFileService {
    static func stage(
        candidate: FinalUploadCandidate,
        reference: EventFolderReference
    ) throws -> StagedFinalUpload {
        let filename = candidate.editedFilename
        
        guard
            filename == (
                filename as NSString
            ).lastPathComponent,
            !filename.isEmpty,
            filename != ".",
            filename != ".."
        else {
            throw FinalUploadFileError
                .invalidFilename(filename)
        }
        
        let resolved = try FolderBookmarkService.resolve(
            reference.bookmarkData
        )
        
        let eventFolderURL = resolved.url
        
        let accessed =
        eventFolderURL
            .startAccessingSecurityScopedResource()
        
        guard accessed else {
            throw FinalUploadFileError
                .eventFolderUnavailable
        }
        
        defer {
            eventFolderURL
                .stopAccessingSecurityScopedResource()
        }
        
        let sourceURL =
        eventFolderURL
            .appendingPathComponent(
                UploadPreparationService
                    .editedFolderName,
                isDirectory: true
            )
            .appendingPathComponent(
                filename,
                isDirectory: false
            )
        
        let sourceValues =
        try sourceURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .fileSizeKey
            ]
        )
        
        guard sourceValues.isRegularFile == true else {
            throw FinalUploadFileError
                .fileMissing(filename)
        }
        
        let byteSize =
        Int64(sourceValues.fileSize ?? 0)
        
        guard
            byteSize
                <= EditedFolderService
                .maximumFinalJPEGBytes
        else {
            throw FinalUploadFileError
                .fileTooLarge(
                    filename,
                    byteSize
                )
        }
        
        let stagingDirectory =
        stagingDirectoryURL(
            photoID: candidate.photoID
        )
        
        if FileManager.default.fileExists(
            atPath: stagingDirectory.path
        ) {
            try FileManager.default.removeItem(
                at: stagingDirectory
            )
        }
        
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        
        let stagedURL =
        stagingDirectory
            .appendingPathComponent(
                filename,
                isDirectory: false
            )
        
        try FileManager.default.copyItem(
            at: sourceURL,
            to: stagedURL
        )
        
        let sha256 =
        try HashingService.sha256Hex(
            for: stagedURL
        )
        
        let variantsDirectory =
        stagingDirectory
            .appendingPathComponent(
                "Variants",
                isDirectory: true
            )
        
        let variants =
        try ImageVariantService
            .createFinalVariants(
                from: stagedURL,
                outputDirectoryURL:
                    variantsDirectory
            )
        
        return StagedFinalUpload(
            fileURL: stagedURL,
            filename: filename,
            sha256: sha256,
            byteSize: byteSize,
            variants: variants
        )
    }
    
    static func removeStagedFile(
        photoID: String
    ) throws {
        let directoryURL =
        stagingDirectoryURL(
            photoID: photoID
        )
        
        guard FileManager.default.fileExists(
            atPath: directoryURL.path
        ) else {
            return
        }
        
        try FileManager.default.removeItem(
            at: directoryURL
        )
    }
    
    private static func stagingDirectoryURL(
        photoID: String
    ) -> URL {
        let fileManager =
        FileManager.default
        
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
                "FinalUploadStaging",
                isDirectory: true
            )
            .appendingPathComponent(
                photoID,
                isDirectory: true
            )
    }
}
