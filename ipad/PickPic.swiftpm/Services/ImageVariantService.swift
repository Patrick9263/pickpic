import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct GeneratedImageVariant: Sendable {
    let fileURL: URL
    let filename: String
    
    let byteSize: Int64
    let pixelWidth: Int
    let pixelHeight: Int
}

struct GeneratedFinalVariants: Sendable {
    let thumbnail: GeneratedImageVariant
    let preview: GeneratedImageVariant
}

enum ImageVariantError: LocalizedError {
    case invalidImageDimensions
    case invalidMaximumSize
    case unableToDecodeFinal
    case unableToCreateColorSpace
    case outputFileMissing(String)
    case outputFileTooLarge(
        filename: String,
        byteSize: Int64,
        maximumByteSize: Int64
    )
    
    var errorDescription: String? {
        switch self {
        case .invalidImageDimensions:
            return """
            The decoded image has invalid dimensions.
            """
            
        case .invalidMaximumSize:
            return """
            The requested image size is invalid.
            """
            
        case .unableToDecodeFinal:
            return """
            PickPic could not decode the final JPEG.
            """
            
        case .unableToCreateColorSpace:
            return """
            PickPic could not create the JPEG color space.
            """
            
        case let .outputFileMissing(filename):
            return """
            PickPic could not create \(filename).
            """
            
        case let .outputFileTooLarge(
            filename,
            byteSize,
            maximumByteSize
        ):
            let actualSize =
            ByteCountFormatter.string(
                fromByteCount: byteSize,
                countStyle: .file
            )
            
            let maximumSize =
            ByteCountFormatter.string(
                fromByteCount:
                    maximumByteSize,
                countStyle: .file
            )
            
            return """
            \(filename) is \(actualSize). It must be \
            \(maximumSize) or smaller.
            """
        }
    }
}

enum ImageVariantService {
    static let thumbnailMaxLongEdge:
    CGFloat = 768
    
    static let previewMaxLongEdge:
    CGFloat = 2_048
    
    static let thumbnailJPEGQuality = 0.78
    static let previewJPEGQuality = 0.85
    
    static let maximumThumbnailBytes:
    Int64 = 2 * 1_024 * 1_024
    
    static let maximumPreviewBytes:
    Int64 = 10 * 1_024 * 1_024
    
    static func boundedImage(
        from image: CIImage,
        maxLongEdge: CGFloat
    ) throws -> CIImage {
        guard maxLongEdge > 0 else {
            throw ImageVariantError
                .invalidMaximumSize
        }
        
        let extent = image.extent
        
        guard
            !extent.isEmpty,
            !extent.isInfinite,
            extent.width.isFinite,
            extent.height.isFinite,
            extent.width > 0,
            extent.height > 0
        else {
            throw ImageVariantError
                .invalidImageDimensions
        }
        
        let normalizedImage =
        image.transformed(
            by: CGAffineTransform(
                translationX:
                    -extent.minX,
                y:
                    -extent.minY
            )
        )
        
        let normalizedExtent =
        normalizedImage.extent
        
        let longEdge = max(
            normalizedExtent.width,
            normalizedExtent.height
        )
        
        guard longEdge > maxLongEdge else {
            return normalizedImage
        }
        
        let scale =
        maxLongEdge / longEdge
        
        return normalizedImage.transformed(
            by: CGAffineTransform(
                scaleX: scale,
                y: scale
            ),
            highQualityDownsample: true
        )
    }
    
    static func createFinalVariants(
        from sourceURL: URL,
        outputDirectoryURL: URL
    ) throws -> GeneratedFinalVariants {
        guard
            let sourceImage =
                CIImage(
                    contentsOf: sourceURL,
                    options: [
                        .applyOrientationProperty:
                            true
                    ]
                )
        else {
            throw ImageVariantError
                .unableToDecodeFinal
        }
        
        let previewImage =
        try boundedImage(
            from: sourceImage,
            maxLongEdge:
                previewMaxLongEdge
        )
        
        let thumbnailImage =
        try boundedImage(
            from: previewImage,
            maxLongEdge:
                thumbnailMaxLongEdge
        )
        
        if FileManager.default.fileExists(
            atPath:
                outputDirectoryURL.path
        ) {
            try FileManager.default.removeItem(
                at: outputDirectoryURL
            )
        }
        
        try FileManager.default.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )
        
        guard
            let colorSpace =
                CGColorSpace(
                    name: CGColorSpace.sRGB
                )
        else {
            throw ImageVariantError
                .unableToCreateColorSpace
        }
        
        let context = CIContext(
            options: [
                .cacheIntermediates: false
            ]
        )
        defer {
            context.clearCaches()
        }
        
        let preview =
        try renderJPEG(
            image: previewImage,
            filename:
                "preview.jpg",
            quality:
                previewJPEGQuality,
            maximumByteSize:
                maximumPreviewBytes,
            outputDirectoryURL:
                outputDirectoryURL,
            context: context,
            colorSpace: colorSpace
        )
        
        let thumbnail =
        try renderJPEG(
            image: thumbnailImage,
            filename:
                "thumbnail.jpg",
            quality:
                thumbnailJPEGQuality,
            maximumByteSize:
                maximumThumbnailBytes,
            outputDirectoryURL:
                outputDirectoryURL,
            context: context,
            colorSpace: colorSpace
        )
        
        return GeneratedFinalVariants(
            thumbnail: thumbnail,
            preview: preview
        )
    }
    
    private static func renderJPEG(
        image: CIImage,
        filename: String,
        quality: Double,
        maximumByteSize: Int64,
        outputDirectoryURL: URL,
        context: CIContext,
        colorSpace: CGColorSpace
    ) throws -> GeneratedImageVariant {
        let outputURL =
        outputDirectoryURL
            .appendingPathComponent(
                filename,
                isDirectory: false
            )
        
        let compressionOption =
        CIImageRepresentationOption(
            rawValue:
                kCGImageDestinationLossyCompressionQuality
            as String
        )
        
        try context.writeJPEGRepresentation(
            of: image,
            to: outputURL,
            colorSpace: colorSpace,
            options: [
                compressionOption: quality
            ]
        )
        
        let values =
        try outputURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .fileSizeKey
            ]
        )
        
        guard values.isRegularFile == true else {
            throw ImageVariantError
                .outputFileMissing(filename)
        }
        
        let byteSize =
        Int64(values.fileSize ?? 0)
        
        guard
            byteSize > 0,
            byteSize <= maximumByteSize
        else {
            try? FileManager.default.removeItem(
                at: outputURL
            )
            
            throw ImageVariantError
                .outputFileTooLarge(
                    filename: filename,
                    byteSize: byteSize,
                    maximumByteSize:
                        maximumByteSize
                )
        }
        
        let extent = image.extent
        
        return GeneratedImageVariant(
            fileURL: outputURL,
            filename: filename,
            byteSize: byteSize,
            pixelWidth:
                max(
                    1,
                    Int(extent.width.rounded())
                ),
            pixelHeight:
                max(
                    1,
                    Int(extent.height.rounded())
                )
        )
    }
}
