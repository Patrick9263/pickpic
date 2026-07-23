import Foundation

struct APIClient {
    let baseURL: URL
    let clientID: String
    let clientSecret: String
    
    private let session: URLSession
    private static let filenameHeaderAllowed =
    CharacterSet(
        charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    
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
    
    func uploadPreparedPhoto(
        _ preparedPhoto: PreparedPhoto,
        from fileURL: URL,
        to eventID: String
    ) async throws -> PhotoUploadOutcome {
        let fileValues = try? fileURL.resourceValues(
            forKeys: [
                .isRegularFileKey
            ]
        )
        
        guard fileValues?.isRegularFile == true else {
            throw APIClientError.preparedFileMissing(
                preparedPhoto.sourceFilename
            )
        }
        
        guard
            let encodedFilename =
                preparedPhoto.sourceFilename
                .addingPercentEncoding(
                    withAllowedCharacters:
                        Self.filenameHeaderAllowed
                )
        else {
            throw APIClientError.invalidUploadFilename(
                preparedPhoto.sourceFilename
            )
        }
        
        let url = baseURL
            .appending(path: "api")
            .appending(path: "admin")
            .appending(path: "events")
            .appending(path: eventID)
            .appending(path: "photos")
        
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        
        request.setValue(
            "image/jpeg",
            forHTTPHeaderField: "Content-Type"
        )
        
        request.setValue(
            clientID,
            forHTTPHeaderField:
                "CF-Access-Client-Id"
        )
        
        request.setValue(
            clientSecret,
            forHTTPHeaderField:
                "CF-Access-Client-Secret"
        )
        
        request.setValue(
            encodedFilename,
            forHTTPHeaderField: "X-File-Name"
        )
        
        request.setValue(
            preparedPhoto.sourceSha256,
            forHTTPHeaderField: "X-File-SHA256"
        )
        
        request.setValue(
            String(preparedPhoto.byteSize),
            forHTTPHeaderField: "Content-Length"
        )
        
        if let capturedAt =
            preparedPhoto.metadata.capturedAt {
            request.setValue(
                capturedAt,
                forHTTPHeaderField:
                    "X-PickPic-Captured-At"
            )
        }
        
        if
            let latitude =
                preparedPhoto.metadata.latitude,
            let longitude =
                preparedPhoto.metadata.longitude
        {
            request.setValue(
                String(latitude),
                forHTTPHeaderField:
                    "X-PickPic-Latitude"
            )
            
            request.setValue(
                String(longitude),
                forHTTPHeaderField:
                    "X-PickPic-Longitude"
            )
        }
        
        let (data, response) =
        try await session.upload(
            for: request,
            fromFile: fileURL
        )
        
        guard
            let httpResponse =
                response as? HTTPURLResponse
        else {
            throw APIClientError.invalidResponse
        }
        
        let responseContentType =
        httpResponse.value(
            forHTTPHeaderField: "Content-Type"
        )?
            .lowercased()
        ?? ""
        
        guard
            (200..<300).contains(
                httpResponse.statusCode
            )
        else {
            let serverMessage =
            try? JSONDecoder().decode(
                APIErrorResponse.self,
                from: data
            ).error
            
            let fallbackMessage =
            HTTPURLResponse.localizedString(
                forStatusCode:
                    httpResponse.statusCode
            )
            
            throw APIClientError.server(
                statusCode:
                    httpResponse.statusCode,
                message:
                    serverMessage
                ?? fallbackMessage
            )
        }
        
        guard
            responseContentType.contains(
                "application/json"
            )
        else {
            throw APIClientError.unexpectedResponse
        }
        
        let uploadResponse: PhotoUploadResponse
        
        do {
            uploadResponse =
            try JSONDecoder().decode(
                PhotoUploadResponse.self,
                from: data
            )
        } catch {
            print(
                "Photo upload decoding failed:",
                error
            )
            
            throw APIClientError
                .invalidPhotoUploadResponse
        }
        
        if uploadResponse.duplicate {
            guard
                let existingPhotoID =
                    uploadResponse.existingPhotoId
            else {
                throw APIClientError
                    .invalidPhotoUploadResponse
            }
            
            return .duplicate(
                existingPhotoID:
                    existingPhotoID,
                variant:
                    uploadResponse.duplicateVariant
            )
        }
        
        guard
            let photoID =
                uploadResponse.photo?.id
        else {
            throw APIClientError
                .invalidPhotoUploadResponse
        }
        
        return .uploaded(
            photoID: photoID
        )
    }
    
    func uploadFinalPhoto(
        _ stagedUpload: StagedFinalUpload,
        to photoID: String
    ) async throws -> FinalPhotoUploadResponse {
        let fileValues =
        try? stagedUpload.fileURL.resourceValues(
            forKeys: [
                .isRegularFileKey
            ]
        )
        
        guard fileValues?.isRegularFile == true else {
            throw APIClientError.preparedFileMissing(
                stagedUpload.filename
            )
        }
        
        guard
            let encodedFilename =
                stagedUpload.filename
                .addingPercentEncoding(
                    withAllowedCharacters:
                        Self.filenameHeaderAllowed
                )
        else {
            throw APIClientError.invalidUploadFilename(
                stagedUpload.filename
            )
        }
        
        let url = baseURL
            .appending(path: "api")
            .appending(path: "admin")
            .appending(path: "photos")
            .appending(path: photoID)
            .appending(path: "final")
        
        var request = URLRequest(url: url)
        
        request.httpMethod = "PUT"
        request.timeoutInterval = 300
        
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        
        request.setValue(
            "image/jpeg",
            forHTTPHeaderField: "Content-Type"
        )
        
        request.setValue(
            clientID,
            forHTTPHeaderField:
                "CF-Access-Client-Id"
        )
        
        request.setValue(
            clientSecret,
            forHTTPHeaderField:
                "CF-Access-Client-Secret"
        )
        
        request.setValue(
            encodedFilename,
            forHTTPHeaderField: "X-File-Name"
        )
        
        request.setValue(
            stagedUpload.sha256,
            forHTTPHeaderField:
                "X-File-SHA256"
        )
        
        request.setValue(
            String(stagedUpload.byteSize),
            forHTTPHeaderField:
                "Content-Length"
        )
        
        let (data, response) =
        try await session.upload(
            for: request,
            fromFile: stagedUpload.fileURL
        )
        
        guard
            let httpResponse =
                response as? HTTPURLResponse
        else {
            throw APIClientError.invalidResponse
        }
        
        guard
            (200..<300).contains(
                httpResponse.statusCode
            )
        else {
            let serverMessage =
            try? makeDecoder().decode(
                APIErrorResponse.self,
                from: data
            ).error
            
            let fallbackMessage =
            HTTPURLResponse.localizedString(
                forStatusCode:
                    httpResponse.statusCode
            )
            
            throw APIClientError.server(
                statusCode:
                    httpResponse.statusCode,
                message:
                    serverMessage
                ?? fallbackMessage
            )
        }
        
        let contentType =
        httpResponse.value(
            forHTTPHeaderField:
                "Content-Type"
        )?
            .lowercased()
        ?? ""
        
        guard
            contentType.contains(
                "application/json"
            )
        else {
            throw APIClientError.unexpectedResponse
        }
        
        do {
            return try makeDecoder().decode(
                FinalPhotoUploadResponse.self,
                from: data
            )
        } catch {
            print(
                "Final photo decoding failed:",
                error
            )
            
            throw APIClientError
                .invalidFinalPhotoUploadResponse
        }
    }
    
    func fetchEventPhotos(
        eventID: String
    ) async throws -> [ServerPhotoRecord] {
        let url = baseURL
            .appending(path: "api")
            .appending(path: "admin")
            .appending(path: "events")
            .appending(path: eventID)
            .appending(path: "photos")
        
        var request = URLRequest(url: url)
        
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        
        request.setValue(
            clientID,
            forHTTPHeaderField:
                "CF-Access-Client-Id"
        )
        
        request.setValue(
            clientSecret,
            forHTTPHeaderField:
                "CF-Access-Client-Secret"
        )
        
        let (data, response) =
        try await session.data(for: request)
        
        guard
            let httpResponse =
                response as? HTTPURLResponse
        else {
            throw APIClientError.invalidResponse
        }
        
        guard
            (200..<300).contains(
                httpResponse.statusCode
            )
        else {
            let serverMessage =
            try? makeDecoder().decode(
                APIErrorResponse.self,
                from: data
            ).error
            
            let fallbackMessage =
            HTTPURLResponse.localizedString(
                forStatusCode:
                    httpResponse.statusCode
            )
            
            throw APIClientError.server(
                statusCode:
                    httpResponse.statusCode,
                message:
                    serverMessage
                ?? fallbackMessage
            )
        }
        
        let contentType =
        httpResponse.value(
            forHTTPHeaderField:
                "Content-Type"
        )?
            .lowercased()
        ?? ""
        
        guard contentType.contains(
            "application/json"
        ) else {
            throw APIClientError.unexpectedResponse
        }
        
        do {
            return try makeDecoder().decode(
                EventPhotosResponse.self,
                from: data
            )
            .photos
        } catch {
            print(
                "Event photo decoding failed:",
                error
            )
            
            throw APIClientError
                .invalidPhotoListResponse
        }
    }
    
    func fetchEventPhotoCount(
        eventID: String
    ) async throws -> Int {
        try await fetchEventPhotos(
            eventID: eventID
        )
        .count
    }
    
    func setEventStatus(
        _ status: PickPicEvent.Status,
        for eventID: String
    ) async throws -> PickPicEvent {
        let url = baseURL
            .appending(path: "api")
            .appending(path: "admin")
            .appending(path: "events")
            .appending(path: eventID)
            .appending(path: "status")
        
        var request = URLRequest(url: url)
        
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        
        request.setValue(
            clientID,
            forHTTPHeaderField:
                "CF-Access-Client-Id"
        )
        
        request.setValue(
            clientSecret,
            forHTTPHeaderField:
                "CF-Access-Client-Secret"
        )
        
        request.httpBody =
        try JSONEncoder().encode(
            SetEventStatusRequest(
                status: status.rawValue
            )
        )
        
        let (data, response) =
        try await session.data(
            for: request
        )
        
        guard
            let httpResponse =
                response as? HTTPURLResponse
        else {
            throw APIClientError.invalidResponse
        }
        
        guard
            (200..<300).contains(
                httpResponse.statusCode
            )
        else {
            let serverMessage =
            try? makeDecoder().decode(
                APIErrorResponse.self,
                from: data
            ).error
            
            let fallbackMessage =
            HTTPURLResponse.localizedString(
                forStatusCode:
                    httpResponse.statusCode
            )
            
            throw APIClientError.server(
                statusCode:
                    httpResponse.statusCode,
                message:
                    serverMessage
                ?? fallbackMessage
            )
        }
        
        let contentType =
        httpResponse.value(
            forHTTPHeaderField:
                "Content-Type"
        )?
            .lowercased()
        ?? ""
        
        guard
            contentType.contains(
                "application/json"
            )
        else {
            throw APIClientError.unexpectedResponse
        }
        
        do {
            let responseBody =
            try makeDecoder().decode(
                EventResponse.self,
                from: data
            )
            
            return responseBody.event
        } catch {
            print(
                "Event status decoding failed:",
                error
            )
            
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
