import Foundation

struct EventListResponse: Decodable {
    let events: [PickPicEvent]
}

struct APIErrorResponse: Decodable {
    let error: String
}

enum APIClientError: LocalizedError {
    case notConfigured
    case invalidResponse
    case unexpectedResponse
    case server(statusCode: Int, message: String)
    case invalidEventData
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "PickPic connection settings have not been configured."
            
        case .invalidResponse:
            return "PickPic returned an invalid network response."
            
        case .unexpectedResponse:
            return """
            PickPic returned a non-JSON response. Check the Cloudflare \
            Access credentials and policy.
            """
            
        case let .server(statusCode, message):
            return "\(message) (HTTP \(statusCode))"
            
        case .invalidEventData:
            return "PickPic returned event data that the app could not read."
        }
    }
}
