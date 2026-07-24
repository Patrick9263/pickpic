import Foundation

enum EditedFolderError: LocalizedError {
    case eventFolderUnavailable
    case editedFolderMissing
    
    var errorDescription: String? {
        switch self {
        case .eventFolderUnavailable:
            return """
            PickPic could not access the saved event folder. \
            Select the event folder again.
            """
            
        case .editedFolderMissing:
            return """
            The Edited folder could not be found. Prepare an \
            upload for this event first.
            """
        }
    }
}

enum EditedFolderService {
    static let maximumFinalJPEGBytes:
    Int64 = 50 * 1_024 * 1_024
    
    static func scan(
        reference: EventFolderReference,
        photos: [ServerPhotoRecord]
    ) throws -> FinalUploadScanResult {
        let resolved = try FolderBookmarkService.resolve(
            reference.bookmarkData
        )
        
        let eventFolderURL = resolved.url
        
        let accessed =
        eventFolderURL
            .startAccessingSecurityScopedResource()
        
        guard accessed else {
            throw EditedFolderError
                .eventFolderUnavailable
        }
        
        defer {
            eventFolderURL
                .stopAccessingSecurityScopedResource()
        }
        
        let editedFolderURL =
        eventFolderURL.appendingPathComponent(
            UploadPreparationService
                .editedFolderName,
            isDirectory: true
        )
        
        var editedIsDirectory: ObjCBool = false
        
        guard
            FileManager.default.fileExists(
                atPath: editedFolderURL.path,
                isDirectory: &editedIsDirectory
            ),
            editedIsDirectory.boolValue
        else {
            throw EditedFolderError
                .editedFolderMissing
        }
        
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey
        ]
        
        let fileURLs =
        try FileManager.default
            .contentsOfDirectory(
                at: editedFolderURL,
                includingPropertiesForKeys:
                    Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
        
        let supportedExtensions: Set<String> = [
            "jpg",
            "jpeg"
        ]
        
        let editedFiles: [(url: URL, byteSize: Int64)] =
        try fileURLs.compactMap {
            (fileURL: URL)
            throws -> (
                url: URL,
                byteSize: Int64
            )? in
            
            let values =
            try fileURL.resourceValues(
                forKeys: resourceKeys
            )
            
            guard values.isRegularFile == true else {
                return nil
            }
            
            guard supportedExtensions.contains(
                fileURL.pathExtension.lowercased()
            ) else {
                return nil
            }
            
            return (
                fileURL,
                Int64(values.fileSize ?? 0)
            )
        }
        
        let eligiblePhotos = photos.filter { photo in
            photo.heartCount > 0
            || photo.workflowStatus == .editing
        }
        
        let photosByBaseName = Dictionary(
            grouping: eligiblePhotos
        ) { photo in
            normalizedBaseName(
                photo.originalFilename
            )
        }
        
        let filesByBaseName = Dictionary(
            grouping: editedFiles
        ) { editedFile in
            normalizedBaseName(
                editedFile.url.lastPathComponent
            )
        }
        
        var candidates: [FinalUploadCandidate] = []
        var missingSourceFilenames: [String] = []
        var ambiguousMatches: [String] = []
        var oversizedEditedFilenames: [String] = []
        
        for baseName in photosByBaseName.keys.sorted() {
            guard
                let serverMatches =
                    photosByBaseName[baseName]
            else {
                continue
            }
            
            guard serverMatches.count == 1 else {
                let filenames = serverMatches
                    .map(\.originalFilename)
                    .joined(separator: ", ")
                
                ambiguousMatches.append(
                    "Multiple server photos: \(filenames)"
                )
                
                continue
            }
            
            let photo = serverMatches[0]
            
            guard
                let editedMatches =
                    filesByBaseName[baseName],
                !editedMatches.isEmpty
            else {
                missingSourceFilenames.append(
                    photo.originalFilename
                )
                
                continue
            }
            
            guard editedMatches.count == 1 else {
                let filenames = editedMatches
                    .map { match in
                        match.url.lastPathComponent
                    }
                    .joined(separator: ", ")
                
                ambiguousMatches.append(
                    """
                    \(photo.originalFilename) matches \
                    multiple files: \(filenames)
                    """
                )
                
                continue
            }
            
            let editedFile = editedMatches[0]
            let editedFilename =
            editedFile.url.lastPathComponent
            
            guard
                editedFile.byteSize
                    <= maximumFinalJPEGBytes
            else {
                oversizedEditedFilenames.append(
                    editedFilename
                )
                
                continue
            }
            
            candidates.append(
                FinalUploadCandidate(
                    photoID: photo.id,
                    sourceFilename:
                        photo.originalFilename,
                    editedFilename:
                        editedFilename,
                    byteSize:
                        editedFile.byteSize,
                    isReplacement:
                        photo.finalPhoto != nil
                )
            )
        }
        
        let allServerBaseNames: Set<String> =
        Set(
            photos.map { photo in
                normalizedBaseName(
                    photo.originalFilename
                )
            }
        )
        
        let unmatchedEditedFilenames =
        filesByBaseName
            .filter { baseName, _ in
                !allServerBaseNames.contains(
                    baseName
                )
            }
            .flatMap { _, files in
                files.map { file in
                    file.url.lastPathComponent
                }
            }
            .sorted {
                $0.localizedStandardCompare($1)
                == .orderedAscending
            }
        
        candidates.sort { first, second in
            first.sourceFilename
                .localizedStandardCompare(
                    second.sourceFilename
                )
            == .orderedAscending
        }
        
        missingSourceFilenames.sort {
            $0.localizedStandardCompare($1)
            == .orderedAscending
        }
        
        ambiguousMatches.sort()
        oversizedEditedFilenames.sort()
        
        let variantRepairCandidates:
        [FinalUploadCandidate] =
        photos.compactMap { photo in
            guard
                photo.workflowStatus == .final,
                photo.heartCount == 0,
                let finalPhoto = photo.finalPhoto,
                !finalPhoto.variants.isComplete
            else {
                return nil
            }
            
            let baseName = normalizedBaseName(
                photo.originalFilename
            )
            
            guard
                let editedMatches =
                    filesByBaseName[baseName],
                editedMatches.count == 1
            else {
                return nil
            }
            
            let editedFile = editedMatches[0]
            
            guard
                editedFile.byteSize
                    <= maximumFinalJPEGBytes
            else {
                return nil
            }
            
            return FinalUploadCandidate(
                photoID: photo.id,
                sourceFilename:
                    photo.originalFilename,
                editedFilename:
                    editedFile.url.lastPathComponent,
                byteSize:
                    editedFile.byteSize,
                isReplacement: true
            )
        }
        .sorted { first, second in
            first.sourceFilename
                .localizedStandardCompare(
                    second.sourceFilename
                )
            == .orderedAscending
        }
        
        return FinalUploadScanResult(
            eligiblePhotoCount:
                eligiblePhotos.count,
            candidates:
                candidates,
            variantRepairCandidates:
                variantRepairCandidates,
            missingSourceFilenames:
                missingSourceFilenames,
            unmatchedEditedFilenames:
                unmatchedEditedFilenames,
            ambiguousMatches:
                ambiguousMatches,
            oversizedEditedFilenames:
                oversizedEditedFilenames
        )
    }
    
    private static func normalizedBaseName(
        _ filename: String
    ) -> String {
        (
            filename as NSString
        )
        .deletingPathExtension
        .lowercased()
    }
}
