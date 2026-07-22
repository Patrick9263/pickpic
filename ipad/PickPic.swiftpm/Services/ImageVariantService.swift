import CoreGraphics
import CoreImage
import Foundation

enum ImageVariantError: LocalizedError {
    case invalidImageDimensions
    case invalidMaximumSize
    
    var errorDescription: String? {
        switch self {
        case .invalidImageDimensions:
            return "The decoded image has invalid dimensions."
            
        case .invalidMaximumSize:
            return "The requested image size is invalid."
        }
    }
}

enum ImageVariantService {
    static func boundedImage(
        from image: CIImage,
        maxLongEdge: CGFloat
    ) throws -> CIImage {
        guard maxLongEdge > 0 else {
            throw ImageVariantError.invalidMaximumSize
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
            throw ImageVariantError.invalidImageDimensions
        }
        
        let normalizedImage = image.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
        
        let normalizedExtent = normalizedImage.extent
        
        let longEdge = max(
            normalizedExtent.width,
            normalizedExtent.height
        )
        
        guard longEdge > maxLongEdge else {
            return normalizedImage
        }
        
        let scale = maxLongEdge / longEdge
        
        return normalizedImage.transformed(
            by: CGAffineTransform(
                scaleX: scale,
                y: scale
            ),
            highQualityDownsample: true
        )
    }
}
