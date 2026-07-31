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
    let sourcePhotoID: String?
    let sourceFilename: String
    let outputFilename: String
    let sourceSha256: String
    
    let byteSize: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    
    let metadata: PhotoMetadata
    let preparedAt: Date
    
    var id: String {
        sourcePhotoID ?? sourceFilename
    }

    init(
        sourcePhotoID: String? = nil,
        sourceFilename: String,
        outputFilename: String,
        sourceSha256: String,
        byteSize: Int64,
        pixelWidth: Int,
        pixelHeight: Int,
        metadata: PhotoMetadata,
        preparedAt: Date
    ) {
        self.sourcePhotoID = sourcePhotoID
        self.sourceFilename = sourceFilename
        self.outputFilename = outputFilename
        self.sourceSha256 = sourceSha256
        self.byteSize = byteSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.metadata = metadata
        self.preparedAt = preparedAt
    }

    func assigned(
        to sourcePhoto: SourcePhoto
    ) -> PreparedPhoto {
        guard sourcePhotoID != sourcePhoto.id else {
            return self
        }

        return PreparedPhoto(
            sourcePhotoID: sourcePhoto.id,
            sourceFilename: sourceFilename,
            outputFilename: outputFilename,
            sourceSha256: sourceSha256,
            byteSize: byteSize,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            metadata: metadata,
            preparedAt: preparedAt
        )
    }
}
