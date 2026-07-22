import Foundation

struct UploadJob:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    let id: UUID
    
    let eventID: String
    let eventTitle: String
    
    let folderName: String
    let folderBookmarkData: Data
    
    let photos: [SourcePhoto]
    
    var stage: UploadStage
    
    let createdAt: Date
    var updatedAt: Date
    
    var preparedAt: Date? = nil
    var errorMessage: String? = nil
    
    var conversionPreview: ConversionPreview? = nil
    var conversionErrorMessage: String? = nil
    
    var photoCount: Int {
        photos.count
    }
    
    var totalBytes: Int64 {
        photos.reduce(0) { result, photo in
            result + photo.byteSize
        }
    }
}
