import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum ImageConversionError: LocalizedError {
    case noSourcePhotos
    case sourceFolderUnavailable
    case sourcePhotoMissing(String)
    case unsupportedRAW(String)
    case unableToDecode(String)
    case unableToCreateColorSpace
    case outputFileMissing
    case outputTooLarge(String, Int64)
    
    var errorDescription: String? {
        switch self {
        case .noSourcePhotos:
            return """
            This upload job does not contain any source photos.
            """
            
        case .sourceFolderUnavailable:
            return """
            PickPic could not access the selected event folder.
            """
            
        case let .sourcePhotoMissing(filename):
            return """
            The source photo \(filename) could not be found.
            """
            
        case let .unsupportedRAW(filename):
            return """
            The RAW file \(filename) could not be decoded on this iPad.
            """
            
        case let .unableToDecode(filename):
            return """
            PickPic could not decode \(filename).
            """
            
        case .unableToCreateColorSpace:
            return """
            PickPic could not create the JPEG color space.
            """
            
        case .outputFileMissing:
            return """
            The converted JPEG could not be read.
            """
            
        case let .outputTooLarge(
            filename,
            byteSize
        ):
            let formattedSize =
            ByteCountFormatter.string(
                fromByteCount: byteSize,
                countStyle: .file
            )
            
            return """
            \(filename) produced a \(formattedSize) JPEG, \
            which exceeds PickPic's 25 MB limit.
            """
        }
    }
}

enum ImageConversionService {
    static let maxLongEdge: CGFloat = 2_400
    static let jpegQuality = 0.82
    
    private static let maximumJPEGBytes:
    Int64 = 25 * 1_024 * 1_024
    
    private struct RenderedJPEG {
        let byteSize: Int64
        let pixelWidth: Int
        let pixelHeight: Int
    }
    
    static func createTestPreview(
        for job: UploadJob
    ) throws -> ConversionPreview {
        guard
            let sourcePhoto =
                job.photos.first(
                    where: { photo in
                        photo.kind == .raw
                    }
                )
                ?? job.photos.first
        else {
            throw ImageConversionError
                .noSourcePhotos
        }
        
        return try withSourceFolder(
            for: job
        ) { folderURL in
            let sourceURL =
            try validatedSourceURL(
                for: sourcePhoto,
                inside: folderURL
            )
            
            let outputFilename =
            "test-preview.jpg"
            
            let outputURL = previewURL(
                jobID: job.id,
                outputFilename:
                    outputFilename
            )
            
            let renderedJPEG =
            try renderJPEG(
                sourceURL: sourceURL,
                sourcePhoto: sourcePhoto,
                outputURL: outputURL
            )
            
            return ConversionPreview(
                sourceFilename:
                    sourcePhoto.filename,
                outputFilename:
                    outputFilename,
                byteSize:
                    renderedJPEG.byteSize,
                pixelWidth:
                    renderedJPEG.pixelWidth,
                pixelHeight:
                    renderedJPEG.pixelHeight,
                convertedAt:
                    Date()
            )
        }
    }
    
    static func createPreparedPhoto(
        sourcePhoto: SourcePhoto,
        index: Int,
        job: UploadJob
    ) throws -> PreparedPhoto {
        try withSourceFolder(
            for: job
        ) { folderURL in
            let sourceURL =
            try validatedSourceURL(
                for: sourcePhoto,
                inside: folderURL
            )
            
            let metadata =
            PhotoMetadataService.extract(
                from: sourceURL
            )
            
            let sourceSha256 =
            try HashingService.sha256Hex(
                for: sourceURL
            )
            
            let outputFilename =
            preparedOutputFilename(
                for: sourcePhoto,
                index: index
            )
            
            let outputURL =
            preparedPhotoURL(
                jobID: job.id,
                outputFilename:
                    outputFilename
            )
            
            let renderedJPEG =
            try renderJPEG(
                sourceURL: sourceURL,
                sourcePhoto: sourcePhoto,
                outputURL: outputURL
            )
            
            return PreparedPhoto(
                sourceFilename:
                    sourcePhoto.filename,
                outputFilename:
                    outputFilename,
                sourceSha256:
                    sourceSha256,
                byteSize:
                    renderedJPEG.byteSize,
                pixelWidth:
                    renderedJPEG.pixelWidth,
                pixelHeight:
                    renderedJPEG.pixelHeight,
                metadata:
                    metadata,
                preparedAt:
                    Date()
            )
        }
    }
    
    static func previewURL(
        jobID: UUID,
        outputFilename: String
    ) -> URL {
        previewDirectoryURL(
            jobID: jobID
        )
        .appendingPathComponent(
            outputFilename,
            isDirectory: false
        )
    }
    
    static func preparedPhotoURL(
        jobID: UUID,
        outputFilename: String
    ) -> URL {
        preparedDirectoryURL(
            jobID: jobID
        )
        .appendingPathComponent(
            outputFilename,
            isDirectory: false
        )
    }
    
    static func resetPreparedPhotos(
        for jobID: UUID
    ) throws {
        let directoryURL =
        preparedDirectoryURL(
            jobID: jobID
        )
        
        if FileManager.default.fileExists(
            atPath: directoryURL.path
        ) {
            try FileManager.default.removeItem(
                at: directoryURL
            )
        }
        
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }
    
    static func removePreparedPhotos(
        for jobID: UUID
    ) throws {
        let directoryURL =
        preparedDirectoryURL(
            jobID: jobID
        )
        
        guard
            FileManager.default.fileExists(
                atPath: directoryURL.path
            )
        else {
            return
        }
        
        try FileManager.default.removeItem(
            at: directoryURL
        )
    }
    
    static func removePreview(
        for jobID: UUID
    ) throws {
        let directoryURL =
        previewDirectoryURL(
            jobID: jobID
        )
        
        guard
            FileManager.default.fileExists(
                atPath: directoryURL.path
            )
        else {
            return
        }
        
        try FileManager.default.removeItem(
            at: directoryURL
        )
    }
    
    private static func withSourceFolder<T>(
        for job: UploadJob,
        operation: (URL) throws -> T
    ) throws -> T {
        let resolvedFolder =
        try FolderBookmarkService.resolve(
            job.folderBookmarkData
        )
        
        let folderURL =
        resolvedFolder.url
        
        let accessed =
        folderURL
            .startAccessingSecurityScopedResource()
        
        guard accessed else {
            throw ImageConversionError
                .sourceFolderUnavailable
        }
        
        defer {
            folderURL
                .stopAccessingSecurityScopedResource()
        }
        
        return try operation(folderURL)
    }
    
    private static func validatedSourceURL(
        for sourcePhoto: SourcePhoto,
        inside folderURL: URL
    ) throws -> URL {
        let sourceURL =
        folderURL.appendingPathComponent(
            sourcePhoto.filename,
            isDirectory: false
        )
        
        let values =
        try sourceURL.resourceValues(
            forKeys: [
                .isRegularFileKey
            ]
        )
        
        guard values.isRegularFile == true else {
            throw ImageConversionError
                .sourcePhotoMissing(
                    sourcePhoto.filename
                )
        }
        
        return sourceURL
    }
    
    private static func renderJPEG(
        sourceURL: URL,
        sourcePhoto: SourcePhoto,
        outputURL: URL
    ) throws -> RenderedJPEG {
        let sourceImage =
        try loadImage(
            from: sourceURL,
            sourcePhoto: sourcePhoto
        )
        
        let outputImage =
        try ImageVariantService.boundedImage(
            from: sourceImage,
            maxLongEdge: maxLongEdge
        )
        
        let outputDirectory =
        outputURL.deletingLastPathComponent()
        
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        
        if FileManager.default.fileExists(
            atPath: outputURL.path
        ) {
            try FileManager.default.removeItem(
                at: outputURL
            )
        }
        
        guard
            let colorSpace = CGColorSpace(
                name: CGColorSpace.sRGB
            )
        else {
            throw ImageConversionError
                .unableToCreateColorSpace
        }
        
        let compressionOption =
        CIImageRepresentationOption(
            rawValue:
                kCGImageDestinationLossyCompressionQuality
            as String
        )
        
        let options:
        [CIImageRepresentationOption: Any] = [
            compressionOption:
                jpegQuality
        ]
        
        let context = CIContext(
            options: [
                .cacheIntermediates: false
            ]
        )
        
        try context.writeJPEGRepresentation(
            of: outputImage,
            to: outputURL,
            colorSpace: colorSpace,
            options: options
        )
        
        let outputValues =
        try outputURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey
            ]
        )
        
        guard
            outputValues.isRegularFile == true
        else {
            throw ImageConversionError
                .outputFileMissing
        }
        
        let byteSize =
        Int64(outputValues.fileSize ?? 0)
        
        guard
            byteSize <= maximumJPEGBytes
        else {
            try? FileManager.default.removeItem(
                at: outputURL
            )
            
            throw ImageConversionError
                .outputTooLarge(
                    sourcePhoto.filename,
                    byteSize
                )
        }
        
        let outputExtent =
        outputImage.extent
        
        return RenderedJPEG(
            byteSize: byteSize,
            pixelWidth:
                Int(outputExtent.width.rounded()),
            pixelHeight:
                Int(outputExtent.height.rounded())
        )
    }
    
    private static func loadImage(
        from sourceURL: URL,
        sourcePhoto: SourcePhoto
    ) throws -> CIImage {
        switch sourcePhoto.kind {
        case .raw:
            guard
                let rawFilter =
                    CIRAWFilter(
                        imageURL: sourceURL
                    )
            else {
                throw ImageConversionError
                    .unsupportedRAW(
                        sourcePhoto.filename
                    )
            }
            
            rawFilter.isDraftModeEnabled = true
            
            guard
                let outputImage =
                    rawFilter.outputImage
            else {
                throw ImageConversionError
                    .unsupportedRAW(
                        sourcePhoto.filename
                    )
            }
            
            return outputImage
            
        case .jpeg:
            guard
                let image = CIImage(
                    contentsOf: sourceURL,
                    options: [
                        .applyOrientationProperty:
                            true
                    ]
                )
            else {
                throw ImageConversionError
                    .unableToDecode(
                        sourcePhoto.filename
                    )
            }
            
            return image
        }
    }
    
    private static func preparedOutputFilename(
        for sourcePhoto: SourcePhoto,
        index: Int
    ) -> String {
        let baseName =
        (
            sourcePhoto.filename
            as NSString
        )
        .deletingPathExtension
        
        let usableBaseName =
        baseName.isEmpty
        ? "photo"
        : baseName
        
        return String(
            format:
                "%04d-%@.jpg",
            index + 1,
            usableBaseName
        )
    }
    
    private static func previewDirectoryURL(
        jobID: UUID
    ) -> URL {
        applicationSupportURL()
            .appendingPathComponent(
                "ConversionPreviews",
                isDirectory: true
            )
            .appendingPathComponent(
                jobID.uuidString,
                isDirectory: true
            )
    }
    
    private static func preparedDirectoryURL(
        jobID: UUID
    ) -> URL {
        applicationSupportURL()
            .appendingPathComponent(
                "PreparedUploads",
                isDirectory: true
            )
            .appendingPathComponent(
                jobID.uuidString,
                isDirectory: true
            )
    }
    
    private static func applicationSupportURL()
    -> URL
    {
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
        
        return baseURL.appendingPathComponent(
            "PickPic",
            isDirectory: true
        )
    }
}
