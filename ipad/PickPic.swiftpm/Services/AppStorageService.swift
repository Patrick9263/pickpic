import Foundation

struct StorageCleanupResult: Sendable {
    let removedItemCount: Int
    let reclaimedBytes: Int64
}

enum AppStorageError: LocalizedError {
    case unableToReadAvailableCapacity
    
    case insufficientSpace(
        requiredBytes: Int64,
        availableBytes: Int64
    )
    
    var errorDescription: String? {
        switch self {
        case .unableToReadAvailableCapacity:
            return """
            PickPic could not determine how much storage is available.
            """
            
        case let .insufficientSpace(
            requiredBytes,
            availableBytes
        ):
            let required = ByteCountFormatter.string(
                fromByteCount: requiredBytes,
                countStyle: .file
            )
            
            let available = ByteCountFormatter.string(
                fromByteCount: availableBytes,
                countStyle: .file
            )
            
            return """
            PickPic needs approximately \(required) of free space, \
            but only \(available) is currently available.
            """
        }
    }
}

enum AppStorageService {
    private static let megabyte:
    Int64 = 1_024 * 1_024
    
    private static let proofAllowancePerPhoto:
    Int64 = 15 * megabyte
    
    private static let proofProcessingReserve:
    Int64 = 512 * megabyte
    
    private static let finalProcessingReserve:
    Int64 = 256 * megabyte
    
    static let rootURL: URL = {
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
        
        return baseURL.appendingPathComponent(
            "PickPic",
            isDirectory: true
        )
    }()
    
    static var conversionPreviewsURL: URL {
        rootURL.appendingPathComponent(
            "ConversionPreviews",
            isDirectory: true
        )
    }
    
    static var preparedUploadsURL: URL {
        rootURL.appendingPathComponent(
            "PreparedUploads",
            isDirectory: true
        )
    }
    
    static var finalUploadStagingURL: URL {
        rootURL.appendingPathComponent(
            "FinalUploadStaging",
            isDirectory: true
        )
    }
    
    static var multipartUploadsURL: URL {
        rootURL.appendingPathComponent(
            "MultipartUploads",
            isDirectory: true
        )
    }
    
    static func ensureProofBatchCapacity(
        photoCount: Int
    ) throws {
        let safePhotoCount = Int64(
            max(photoCount, 0)
        )
        
        let requiredBytes =
        safePhotoCount
        * proofAllowancePerPhoto
        + proofProcessingReserve
        
        try ensureCapacity(
            requiredBytes: requiredBytes
        )
    }
    
    static func ensureFinalUploadCapacity(
        finalByteSize: Int64
    ) throws {
        // Allows for the staged final, generated variants,
        // multipart body, and working space.
        let variantAndMultipartAllowance:
        Int64 = 24 * megabyte
        
        let requiredBytes =
        max(finalByteSize, 0)
        + variantAndMultipartAllowance
        + finalProcessingReserve
        
        try ensureCapacity(
            requiredBytes: requiredBytes
        )
    }
    
    static func cleanup(
        jobs: [UploadJob]
    ) throws -> StorageCleanupResult {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        
        let preparedJobIDs = Set(
            jobs.compactMap { job -> String? in
                switch job.stage {
                case .readyToUpload,
                        .uploading:
                    return job.id.uuidString
                    
                case .queued,
                        .preparing,
                        .prepared,
                        .converting,
                        .completed,
                        .failed:
                    return nil
                }
            }
        )
        
        let previewJobIDs = Set(
            jobs.compactMap { job -> String? in
                guard job.conversionPreview != nil else {
                    return nil
                }
                
                return job.id.uuidString
            }
        )
        
        var removedItemCount = 0
        var reclaimedBytes: Int64 = 0
        
        let preparedResult = try cleanupChildren(
            inside: preparedUploadsURL,
            keepingNames: preparedJobIDs
        )
        
        removedItemCount +=
        preparedResult.removedItemCount
        
        reclaimedBytes +=
        preparedResult.reclaimedBytes
        
        let previewResult = try cleanupChildren(
            inside: conversionPreviewsURL,
            keepingNames: previewJobIDs
        )
        
        removedItemCount +=
        previewResult.removedItemCount
        
        reclaimedBytes +=
        previewResult.reclaimedBytes
        
        // These operations cannot be resumed from their
        // staging files after the process has ended.
        let finalStagingResult =
        try cleanupChildren(
            inside: finalUploadStagingURL,
            keepingNames: []
        )
        
        removedItemCount +=
        finalStagingResult.removedItemCount
        
        reclaimedBytes +=
        finalStagingResult.reclaimedBytes
        
        let multipartResult =
        try cleanupChildren(
            inside: multipartUploadsURL,
            keepingNames: []
        )
        
        removedItemCount +=
        multipartResult.removedItemCount
        
        reclaimedBytes +=
        multipartResult.reclaimedBytes
        
        return StorageCleanupResult(
            removedItemCount:
                removedItemCount,
            reclaimedBytes:
                reclaimedBytes
        )
    }
    
    private static func ensureCapacity(
        requiredBytes: Int64
    ) throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        
        let availableBytes =
        try availableCapacity()
        
        guard
            availableBytes >= requiredBytes
        else {
            throw AppStorageError
                .insufficientSpace(
                    requiredBytes:
                        requiredBytes,
                    availableBytes:
                        availableBytes
                )
        }
    }
    
    private static func availableCapacity()
    throws -> Int64
    {
        let values =
        try rootURL.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ]
        )
        
        if let capacity =
            values
            .volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        
        let attributes =
        try FileManager.default
            .attributesOfFileSystem(
                forPath: rootURL.path
            )
        
        if let freeSize =
            attributes[
                .systemFreeSize
            ] as? NSNumber {
            return freeSize.int64Value
        }
        
        throw AppStorageError
            .unableToReadAvailableCapacity
    }
    
    private static func cleanupChildren(
        inside directoryURL: URL,
        keepingNames: Set<String>
    ) throws -> StorageCleanupResult {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(
            atPath: directoryURL.path
        ) else {
            return StorageCleanupResult(
                removedItemCount: 0,
                reclaimedBytes: 0
            )
        }
        
        let childURLs =
        try fileManager
            .contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .fileSizeKey
                ],
                options: [.skipsHiddenFiles]
            )
        
        var removedItemCount = 0
        var reclaimedBytes: Int64 = 0
        
        for childURL in childURLs {
            guard
                !keepingNames.contains(
                    childURL.lastPathComponent
                )
            else {
                continue
            }
            
            reclaimedBytes +=
            recursiveFileSize(
                at: childURL
            )
            
            try fileManager.removeItem(
                at: childURL
            )
            
            removedItemCount += 1
        }
        
        return StorageCleanupResult(
            removedItemCount:
                removedItemCount,
            reclaimedBytes:
                reclaimedBytes
        )
    }
    
    private static func recursiveFileSize(
        at url: URL
    ) -> Int64 {
        let fileManager = FileManager.default
        
        let rootValues =
        try? url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .fileSizeKey
            ]
        )
        
        if rootValues?.isRegularFile == true {
            return Int64(
                rootValues?.fileSize ?? 0
            )
        }
        
        guard
            let enumerator =
                fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .fileSizeKey
                    ],
                    options: [
                        .skipsHiddenFiles
                    ]
                )
        else {
            return 0
        }
        
        var totalBytes: Int64 = 0
        
        for case let childURL as URL
                in enumerator {
            let values =
            try? childURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey
                ]
            )
            
            if values?.isRegularFile == true {
                totalBytes += Int64(
                    values?.fileSize ?? 0
                )
            }
        }
        
        return totalBytes
    }
}
