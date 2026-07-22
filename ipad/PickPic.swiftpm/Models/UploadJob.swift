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
    
    var photoCount: Int {
        photos.count
    }
    
    var totalBytes: Int64 {
        photos.reduce(0) { result, photo in
            result + photo.byteSize
        }
    }
}
