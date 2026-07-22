import Foundation

struct UploadPreparationResult: Sendable {
    let preparedAt: Date
}

enum UploadPreparationError: LocalizedError {
    case sourceFolderUnavailable
    case missingSourcePhotos([String])
    
    var errorDescription: String? {
        switch self {
        case .sourceFolderUnavailable:
            return """
            PickPic could not access the selected event folder. \
            Select the folder again and create a new upload job.
            """
            
        case let .missingSourcePhotos(filenames):
            let displayedNames = filenames
                .prefix(3)
                .joined(separator: ", ")
            
            let remainingCount =
            max(filenames.count - 3, 0)
            
            if remainingCount > 0 {
                return """
                Some source photos are missing: \
                \(displayedNames), and \(remainingCount) more.
                """
            }
            
            return """
            Some source photos are missing: \
            \(displayedNames).
            """
        }
    }
}

enum UploadPreparationService {
    static let toEditFolderName = "To Edit"
    static let editedFolderName = "Edited"
    
    static func prepare(
        job: UploadJob
    ) throws -> UploadPreparationResult {
        let resolved = try FolderBookmarkService.resolve(
            job.folderBookmarkData
        )
        
        let folderURL = resolved.url
        
        let accessed =
        folderURL
            .startAccessingSecurityScopedResource()
        
        guard accessed else {
            throw UploadPreparationError
                .sourceFolderUnavailable
        }
        
        defer {
            folderURL
                .stopAccessingSecurityScopedResource()
        }
        
        try validateFolder(folderURL)
        try validatePhotos(
            job.photos,
            inside: folderURL
        )
        
        try createWorkflowFolders(
            inside: folderURL
        )
        
        return UploadPreparationResult(
            preparedAt: Date()
        )
    }
    
    private static func validateFolder(
        _ folderURL: URL
    ) throws {
        var isDirectory: ObjCBool = false
        
        let exists =
        FileManager.default.fileExists(
            atPath: folderURL.path,
            isDirectory: &isDirectory
        )
        
        guard exists, isDirectory.boolValue else {
            throw UploadPreparationError
                .sourceFolderUnavailable
        }
    }
    
    private static func validatePhotos(
        _ photos: [SourcePhoto],
        inside folderURL: URL
    ) throws {
        var missingFilenames: [String] = []
        
        for photo in photos {
            let photoURL =
            folderURL.appendingPathComponent(
                photo.filename,
                isDirectory: false
            )
            
            var isDirectory: ObjCBool = false
            
            let exists =
            FileManager.default.fileExists(
                atPath: photoURL.path,
                isDirectory: &isDirectory
            )
            
            if !exists || isDirectory.boolValue {
                missingFilenames.append(
                    photo.filename
                )
            }
        }
        
        guard missingFilenames.isEmpty else {
            throw UploadPreparationError
                .missingSourcePhotos(
                    missingFilenames
                )
        }
    }
    
    private static func createWorkflowFolders(
        inside folderURL: URL
    ) throws {
        let fileManager = FileManager.default
        
        let toEditURL =
        folderURL.appendingPathComponent(
            toEditFolderName,
            isDirectory: true
        )
        
        let editedURL =
        folderURL.appendingPathComponent(
            editedFolderName,
            isDirectory: true
        )
        
        try fileManager.createDirectory(
            at: toEditURL,
            withIntermediateDirectories: true
        )
        
        try fileManager.createDirectory(
            at: editedURL,
            withIntermediateDirectories: true
        )
    }
}
