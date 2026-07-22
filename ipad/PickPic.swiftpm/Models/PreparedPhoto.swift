import Foundation

struct PhotoMetadata:
    Codable,
    Hashable,
    Sendable
{
    let capturedAt: String?
    let latitude: Double?
    let longitude: Double?
    
    static let empty = PhotoMetadata(
        capturedAt: nil,
        latitude: nil,
        longitude: nil
    )
}

struct PreparedPhoto:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    let sourceFilename: String
    let outputFilename: String
    let sourceSha256: String
    
    let byteSize: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    
    let metadata: PhotoMetadata
    let preparedAt: Date
    
    var id: String {
        sourceFilename
    }
}
