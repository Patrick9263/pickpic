import Foundation

struct EventListResponse: Decodable {
    let events: [PickPicEvent]
}

struct EventResponse: Decodable {
    let event: PickPicEvent
}

struct CreateEventRequest: Encodable {
    let title: String

    /*
     * Supplying the id makes creation idempotent, so an event first
     * named offline keeps its identity and a retry cannot leave a
     * duplicate behind.
     */
    let id: String?
}

struct UpdateEventRequest: Encodable {
    let title: String
}

struct DeleteEventResponse: Decodable {
    let deleted: Bool
    let eventId: String
}

struct EventPhotosResponse: Decodable {
    let photos: [ServerPhotoRecord]
}

struct PhotoPreflightRequest: Encodable {
    let filenames: [String]
}

struct PhotoPreflightResponse: Decodable {
    let matches: [PreflightMatch]
}

struct SetPhotoWorkflowRequest: Encodable {
    let status: String
}

struct PhotoWorkflowResponse: Decodable {
    let photoId: String
    let workflowStatus: ServerPhotoWorkflowStatus
    let heartCount: Int
}

enum ServerPhotoWorkflowStatus:
    String,
    Decodable,
    Hashable,
    Sendable
{
    case idle
    case editing
    case final
    
    var title: String {
        switch self {
        case .idle:
            return "Waiting"
            
        case .editing:
            return "Editing"
            
        case .final:
            return "Final"
        }
    }
    
    var systemImage: String {
        switch self {
        case .idle:
            return "clock"
            
        case .editing:
            return "slider.horizontal.3"
            
        case .final:
            return "checkmark.circle.fill"
        }
    }
}


enum ServerPhotoVariantSourceKind:
    String,
    Sendable
{
    case original
    case final
}

struct ServerImageVariantRecord:
    Decodable,
    Hashable,
    Sendable
{
    let imageUrl: String
    let contentType: String
    let byteSize: Int64
    let width: Int
    let height: Int
    let createdAt: String
}

struct ServerImageVariantSet:
    Decodable,
    Hashable,
    Sendable
{
    let thumbnail: ServerImageVariantRecord?
    let preview: ServerImageVariantRecord?
    var isComplete: Bool {
        thumbnail != nil && preview != nil
    }
}

struct ServerFinalPhotoSummary:
    Decodable,
    Hashable,
    Sendable
{
    let originalFilename: String
    let byteSize: Int64
    let uploadedAt: String
    let variants: ServerImageVariantSet
}

struct FinalVariantUploadResponse:
    Decodable,
    Sendable
{
    let photoId: String
    let sourceKind: String
    let variants: ServerImageVariantSet
}

struct ServerPhotoRecord:
    Identifiable,
    Decodable,
    Hashable,
    Sendable
{
    let id: String
    let originalFilename: String
    let heartCount: Int
    let workflowStatus: ServerPhotoWorkflowStatus
    let variants: ServerImageVariantSet
    let finalPhoto: ServerFinalPhotoSummary?
}

struct EventPhotoStatistics:
    Hashable,
    Sendable
{
    let uploadedProofCount: Int
    let likedPhotoCount: Int
    let totalHeartCount: Int
    let editingPhotoCount: Int
    let uploadedFinalCount: Int
    let missingVariantPhotoCount: Int

    static let empty = EventPhotoStatistics(
        uploadedProofCount: 0,
        likedPhotoCount: 0,
        totalHeartCount: 0,
        editingPhotoCount: 0,
        uploadedFinalCount: 0,
        missingVariantPhotoCount: 0
    )

    init(
        uploadedProofCount: Int,
        likedPhotoCount: Int,
        totalHeartCount: Int,
        editingPhotoCount: Int,
        uploadedFinalCount: Int,
        missingVariantPhotoCount: Int
    ) {
        self.uploadedProofCount =
        uploadedProofCount
        self.likedPhotoCount =
        likedPhotoCount
        self.totalHeartCount =
        totalHeartCount
        self.editingPhotoCount =
        editingPhotoCount
        self.uploadedFinalCount =
        uploadedFinalCount
        self.missingVariantPhotoCount =
        missingVariantPhotoCount
    }

    init(photos: [ServerPhotoRecord]) {
        uploadedProofCount = photos.count

        likedPhotoCount =
        photos.filter { photo in
            photo.heartCount > 0
        }
        .count

        totalHeartCount =
        photos.reduce(0) { total, photo in
            total + photo.heartCount
        }

        editingPhotoCount =
        photos.filter { photo in
            photo.workflowStatus == .editing
        }
        .count

        uploadedFinalCount =
        photos.filter { photo in
            photo.finalPhoto != nil
        }
        .count

        missingVariantPhotoCount =
        photos.filter { photo in
            !photo.variants.isComplete
            || (
                photo.finalPhoto != nil
                && photo.finalPhoto?.variants
                    .isComplete == false
            )
        }
        .count
    }
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

struct FinalPhotoUploadResponse:
    Decodable,
    Sendable
{
    let photoId: String
    let workflowStatus: ServerPhotoWorkflowStatus
    let heartCount: Int
    let finalPhoto: ServerFinalPhotoSummary
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
    case invalidEventMutationResponse
    case invalidEventDeletionResponse
    case invalidPhotoListResponse
    case invalidPhotoWorkflowResponse
    case preparedFileMissing(String)
    case invalidUploadFilename(String)
    case invalidPhotoUploadResponse
    case invalidFinalPhotoUploadResponse
    case invalidFinalVariantUploadResponse
    
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
            
        case .invalidEventMutationResponse:
            return """
            PickPic returned updated event data that the app could not read.
            """
            
        case .invalidEventDeletionResponse:
            return """
            PickPic did not confirm that the event was deleted.
            """
            
        case .invalidPhotoListResponse:
            return """
            PickPic returned a photo list that the app could not read.
            """
            
        case .invalidPhotoWorkflowResponse:
            return """
            PickPic returned workflow data that the app could not read.
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
            
        case .invalidFinalPhotoUploadResponse:
            return """
            PickPic returned final-photo data that the app could not read.
            """
            
        case .invalidFinalVariantUploadResponse:
            return """
            PickPic returned optimized-image data that the app \
            could not read.
            """
        }
    }
}
