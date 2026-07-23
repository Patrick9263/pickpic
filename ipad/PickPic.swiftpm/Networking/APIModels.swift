import Foundation

struct EventListResponse: Decodable {
    let events: [PickPicEvent]
}

struct EventResponse: Decodable {
    let event: PickPicEvent
}

struct EventPhotosResponse: Decodable {
    let photos: [ServerPhotoSummary]
}

struct ServerPhotoSummary: Decodable {
    let id: String
}

struct SetEventStatusRequest: Encodable {
    let status: String
}

struct APIErrorResponse: Decodable {
    let error: String
}

struct PhotoUploadResponse: Decodable {
    let duplicate: Bool
    
    let existingPhotoId: String?
    let duplicateVariant: String?
    
    let photo: UploadedPhotoResponse?
}

struct UploadedPhotoResponse: Decodable {
    let id: String
}

enum PhotoUploadOutcome: Sendable {
    case uploaded(photoID: String)
    
    case duplicate(
        existingPhotoID: String,
        variant: String?
    )
}

enum APIClientError: LocalizedError {
    case notConfigured
    case invalidResponse
    case unexpectedResponse
    
    case server(
        statusCode: Int,
        message: String
    )
    
    case invalidEventData
    case invalidPhotoListResponse
    
    case preparedFileMissing(String)
    case invalidUploadFilename(String)
    case invalidPhotoUploadResponse
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return """
            PickPic connection settings have not been configured.
            """
            
        case .invalidResponse:
            return """
            PickPic returned an invalid network response.
            """
            
        case .unexpectedResponse:
            return """
            PickPic returned a non-JSON response. Check the \
            Cloudflare Access credentials and policy.
            """
            
        case let .server(statusCode, message):
            return "\(message) (HTTP \(statusCode))"
            
        case .invalidEventData:
            return """
            PickPic returned event data that the app could not read.
            """
            
        case .invalidPhotoListResponse:
            return """
            PickPic returned a photo list that the app could not read.
            """
            
        case let .preparedFileMissing(filename):
            return """
            The prepared JPEG for \(filename) could not be found. \
            Convert the batch again.
            """
            
        case let .invalidUploadFilename(filename):
            return """
            The filename \(filename) could not be encoded for upload.
            """
            
        case .invalidPhotoUploadResponse:
            return """
            PickPic returned upload data that the app could not read.
            """
        }
    }
}
