import Foundation

struct APIClient {
    let baseURL: URL
    let clientID: String
    let clientSecret: String
    
    private let session: URLSession
    
    init(
        baseURL: URL,
        clientID: String,
        clientSecret: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.session = session
    }
    
    func fetchEvents() async throws -> [PickPicEvent] {
        let url = baseURL
            .appending(path: "api")
            .appending(path: "admin")
            .appending(path: "events")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            clientID,
            forHTTPHeaderField: "CF-Access-Client-Id"
        )
        request.setValue(
            clientSecret,
            forHTTPHeaderField: "CF-Access-Client-Secret"
        )
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        
        let decoder = makeDecoder()
        
        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverMessage =
            try? decoder.decode(
                APIErrorResponse.self,
                from: data
            ).error
            
            let fallbackMessage = HTTPURLResponse.localizedString(
                forStatusCode: httpResponse.statusCode
            )
            
            throw APIClientError.server(
                statusCode: httpResponse.statusCode,
                message: serverMessage ?? fallbackMessage
            )
        }
        
        let contentType =
        httpResponse.value(
            forHTTPHeaderField: "Content-Type"
        )?
            .lowercased()
        ?? ""
        
        guard contentType.contains("application/json") else {
            print(
                "Unexpected events response:",
                httpResponse.statusCode,
                contentType
            )
            
            throw APIClientError.unexpectedResponse
        }
        
        do {
            let responseBody = try decoder.decode(
                EventListResponse.self,
                from: data
            )
            
            return responseBody.events
        } catch {
            print("Event decoding failed:", error)
            throw APIClientError.invalidEventData
        }
    }
    
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [
            .withInternetDateTime
        ]
        
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            
            if let date = fractionalFormatter.date(from: value)
                ?? standardFormatter.date(from: value) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date: \(value)"
            )
        }
        
        return decoder
    }
}
