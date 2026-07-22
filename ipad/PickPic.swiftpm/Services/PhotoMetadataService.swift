import Foundation
import ImageIO

enum PhotoMetadataService {
    static func extract(
        from fileURL: URL
    ) -> PhotoMetadata {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        
        guard
            let imageSource =
                CGImageSourceCreateWithURL(
                    fileURL as CFURL,
                    options as CFDictionary
                ),
            let properties =
                CGImageSourceCopyPropertiesAtIndex(
                    imageSource,
                    0,
                    nil
                ) as NSDictionary?
        else {
            return .empty
        }
        
        let exif =
        properties[
            kCGImagePropertyExifDictionary
        ] as? NSDictionary
        
        let tiff =
        properties[
            kCGImagePropertyTIFFDictionary
        ] as? NSDictionary
        
        let gps =
        properties[
            kCGImagePropertyGPSDictionary
        ] as? NSDictionary
        
        let capturedAt = normalizedCaptureDate(
            from:
                stringValue(
                    exif?[
                        kCGImagePropertyExifDateTimeOriginal
                    ]
                )
            ?? stringValue(
                exif?[
                    kCGImagePropertyExifDateTimeDigitized
                ]
            )
            ?? stringValue(
                tiff?[
                    kCGImagePropertyTIFFDateTime
                ]
            )
        )
        
        let latitudeValue = numberValue(
            gps?[
                kCGImagePropertyGPSLatitude
            ]
        )
        
        let longitudeValue = numberValue(
            gps?[
                kCGImagePropertyGPSLongitude
            ]
        )
        
        let latitudeReference = stringValue(
            gps?[
                kCGImagePropertyGPSLatitudeRef
            ]
        )
        
        let longitudeReference = stringValue(
            gps?[
                kCGImagePropertyGPSLongitudeRef
            ]
        )
        
        guard
            let rawLatitude = latitudeValue,
            let rawLongitude = longitudeValue
        else {
            return PhotoMetadata(
                capturedAt: capturedAt,
                latitude: nil,
                longitude: nil
            )
        }
        
        let latitude = signedCoordinate(
            rawLatitude,
            reference: latitudeReference,
            negativeReference: "S"
        )
        
        let longitude = signedCoordinate(
            rawLongitude,
            reference: longitudeReference,
            negativeReference: "W"
        )
        
        guard
            latitude >= -90,
            latitude <= 90,
            longitude >= -180,
            longitude <= 180
        else {
            return PhotoMetadata(
                capturedAt: capturedAt,
                latitude: nil,
                longitude: nil
            )
        }
        
        return PhotoMetadata(
            capturedAt: capturedAt,
            latitude: latitude,
            longitude: longitude
        )
    }
    
    private static func stringValue(
        _ value: Any?
    ) -> String? {
        if let value = value as? String {
            return value
        }
        
        if let value = value as? NSString {
            return value as String
        }
        
        return nil
    }
    
    private static func numberValue(
        _ value: Any?
    ) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        
        if let value = value as? Double {
            return value
        }
        
        return nil
    }
    
    private static func signedCoordinate(
        _ value: Double,
        reference: String?,
        negativeReference: String
    ) -> Double {
        guard let reference else {
            return value
        }
        
        if reference.uppercased()
            == negativeReference {
            return -abs(value)
        }
        
        return abs(value)
    }
    
    private static func normalizedCaptureDate(
        from value: String?
    ) -> String? {
        guard let value else {
            return nil
        }
        
        let trimmedValue =
        value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        
        let candidate =
        String(trimmedValue.prefix(19))
        
        let inputFormats = [
            "yyyy:MM:dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]
        
        for inputFormat in inputFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(
                identifier: "en_US_POSIX"
            )
            formatter.calendar = Calendar(
                identifier: .gregorian
            )
            formatter.timeZone = TimeZone(
                secondsFromGMT: 0
            )
            formatter.dateFormat = inputFormat
            formatter.isLenient = false
            
            guard
                let date = formatter.date(
                    from: candidate
                )
            else {
                continue
            }
            
            let outputFormatter =
            DateFormatter()
            
            outputFormatter.locale = Locale(
                identifier: "en_US_POSIX"
            )
            outputFormatter.calendar = Calendar(
                identifier: .gregorian
            )
            outputFormatter.timeZone = TimeZone(
                secondsFromGMT: 0
            )
            outputFormatter.dateFormat =
            "yyyy-MM-dd'T'HH:mm:ss"
            
            return outputFormatter.string(
                from: date
            )
        }
        
        return nil
    }
}
