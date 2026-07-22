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
    
    var preparedAt: Date?
    var errorMessage: String?
    
    var conversionPreview: ConversionPreview?
    var conversionErrorMessage: String?
    
    var preparedPhotos: [PreparedPhoto]
    
    var conversionProcessedCount: Int
    var conversionCurrentFilename: String?
    var conversionStartedAt: Date?
    var conversionCompletedAt: Date?
    
    var photoCount: Int {
        photos.count
    }
    
    var totalBytes: Int64 {
        photos.reduce(0) { result, photo in
            result + photo.byteSize
        }
    }
    
    var preparedByteCount: Int64 {
        preparedPhotos.reduce(
            0
        ) { result, photo in
            result + photo.byteSize
        }
    }
    
    init(
        id: UUID,
        eventID: String,
        eventTitle: String,
        folderName: String,
        folderBookmarkData: Data,
        photos: [SourcePhoto],
        stage: UploadStage,
        createdAt: Date,
        updatedAt: Date,
        preparedAt: Date? = nil,
        errorMessage: String? = nil,
        conversionPreview:
        ConversionPreview? = nil,
        conversionErrorMessage:
        String? = nil,
        preparedPhotos:
        [PreparedPhoto] = [],
        conversionProcessedCount:
        Int = 0,
        conversionCurrentFilename:
        String? = nil,
        conversionStartedAt:
        Date? = nil,
        conversionCompletedAt:
        Date? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.eventTitle = eventTitle
        self.folderName = folderName
        self.folderBookmarkData =
        folderBookmarkData
        self.photos = photos
        self.stage = stage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preparedAt = preparedAt
        self.errorMessage = errorMessage
        self.conversionPreview =
        conversionPreview
        self.conversionErrorMessage =
        conversionErrorMessage
        self.preparedPhotos = preparedPhotos
        self.conversionProcessedCount =
        conversionProcessedCount
        self.conversionCurrentFilename =
        conversionCurrentFilename
        self.conversionStartedAt =
        conversionStartedAt
        self.conversionCompletedAt =
        conversionCompletedAt
    }
    
    private enum CodingKeys:
        String,
        CodingKey
    {
        case id
        case eventID
        case eventTitle
        case folderName
        case folderBookmarkData
        case photos
        case stage
        case createdAt
        case updatedAt
        case preparedAt
        case errorMessage
        case conversionPreview
        case conversionErrorMessage
        case preparedPhotos
        case conversionProcessedCount
        case conversionCurrentFilename
        case conversionStartedAt
        case conversionCompletedAt
    }
    
    init(
        from decoder: Decoder
    ) throws {
        let container =
        try decoder.container(
            keyedBy: CodingKeys.self
        )
        
        id = try container.decode(
            UUID.self,
            forKey: .id
        )
        
        eventID = try container.decode(
            String.self,
            forKey: .eventID
        )
        
        eventTitle = try container.decode(
            String.self,
            forKey: .eventTitle
        )
        
        folderName = try container.decode(
            String.self,
            forKey: .folderName
        )
        
        folderBookmarkData =
        try container.decode(
            Data.self,
            forKey: .folderBookmarkData
        )
        
        photos = try container.decode(
            [SourcePhoto].self,
            forKey: .photos
        )
        
        stage = try container.decode(
            UploadStage.self,
            forKey: .stage
        )
        
        createdAt = try container.decode(
            Date.self,
            forKey: .createdAt
        )
        
        updatedAt = try container.decode(
            Date.self,
            forKey: .updatedAt
        )
        
        preparedAt =
        try container.decodeIfPresent(
            Date.self,
            forKey: .preparedAt
        )
        
        errorMessage =
        try container.decodeIfPresent(
            String.self,
            forKey: .errorMessage
        )
        
        conversionPreview =
        try container.decodeIfPresent(
            ConversionPreview.self,
            forKey: .conversionPreview
        )
        
        conversionErrorMessage =
        try container.decodeIfPresent(
            String.self,
            forKey:
                    .conversionErrorMessage
        )
        
        preparedPhotos =
        try container.decodeIfPresent(
            [PreparedPhoto].self,
            forKey: .preparedPhotos
        )
        ?? []
        
        conversionProcessedCount =
        try container.decodeIfPresent(
            Int.self,
            forKey:
                    .conversionProcessedCount
        )
        ?? 0
        
        conversionCurrentFilename =
        try container.decodeIfPresent(
            String.self,
            forKey:
                    .conversionCurrentFilename
        )
        
        conversionStartedAt =
        try container.decodeIfPresent(
            Date.self,
            forKey:
                    .conversionStartedAt
        )
        
        conversionCompletedAt =
        try container.decodeIfPresent(
            Date.self,
            forKey:
                    .conversionCompletedAt
        )
    }
}
