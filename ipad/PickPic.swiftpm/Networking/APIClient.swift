import Foundation

struct UploadConnectivityCallbacks {
    let onWaiting: () -> Void
    let onResumed: () -> Void
}

private final class UploadConnectivityTaskDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let callbacks: UploadConnectivityCallbacks
    private let lock = NSLock()
    private var reportedWaiting = false

    init(callbacks: UploadConnectivityCallbacks) {
        self.callbacks = callbacks
    }

    func urlSession(
        _ session: URLSession,
        taskIsWaitingForConnectivity task: URLSessionTask
    ) {
        lock.lock()
        let shouldReport = !reportedWaiting
        reportedWaiting = true
        lock.unlock()

        if shouldReport {
            callbacks.onWaiting()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        lock.lock()
        let shouldReport = reportedWaiting
        reportedWaiting = false
        lock.unlock()

        if shouldReport {
            callbacks.onResumed()
        }
    }
}

struct APIClient {
    let baseURL: URL
    let clientID: String
    let clientSecret: String
    
    private let session: URLSession
    private let uploadSession: URLSession

    private static let defaultUploadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()
    private static let filenameHeaderAllowed =
    CharacterSet(
        charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    
    init(
        baseURL: URL,
        clientID: String,
        clientSecret: String,
        session: URLSession = .shared,
        uploadSession: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.session = session
        self.uploadSession =
            uploadSession ?? Self.defaultUploadSession
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
    
    func createEvent(
        title: String
    ) async throws -> PickPicEvent {
        let url = baseURL
            .appending(path: "api")
            .appending(path: "admin")
            .appending(path: "events")
        
        var request = makeAdminJSONRequest(
            url: url
        )
        
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(
            CreateEventRequest(
                title: title
            )
        )
        
        return try await performEventMutation(
            request
        )
    }
    
    func updateEvent(
        title: String,
        eventID: String
    ) async throws -> PickPicEvent {
        let url = baseURL
            .appending(path: "api")
            .appending(path: "admin")
            .appending(path: "events")
            .appending(path: eventID)
        
        var request = makeAdminJSONRequest(
            url: url
        )
        
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(
            UpdateEventRequest(
                title: title
            )
        )
        
        return try await performEventMutation(
            request
        )
    }
    
    func deleteEvent(
        eventID: String
    ) async throws {
        let url = baseURL
            .appending(path: "api")
            .appending(path: "admin")
            .appending(path: "events")
            .appending(path: eventID)
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 60
        
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
        try await session.data(
            for: request
        )
        
        try validateJSONResponse(
            data: data,
            response: response
        )
        
        do {
            let deletionResponse =
            try makeDecoder().decode(
                DeleteEventResponse.self,
                from: data
            )
            
            guard
                deletionResponse.deleted,
                deletionResponse.eventId == eventID
            else {
                throw APIClientError
                    .invalidEventDeletionResponse
            }
        } catch let error as APIClientError {
            throw error
        } catch {
            print(
                "Event deletion decoding failed:",
                error
            )
            
            throw APIClientError
                .invalidEventDeletionResponse
        }
    }
    
    func uploadPreparedPhoto(
        _ preparedPhoto: PreparedPhoto,
        from fileURL: URL,
        to eventID: String,
        connectivityCallbacks:
        UploadConnectivityCallbacks? = nil
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
        
        let connectivityDelegate =
        connectivityCallbacks.map { callbacks in
            UploadConnectivityTaskDelegate(
                callbacks: callbacks
            )
        }

        let (data, response) =
        try await uploadSession.upload(
            for: request,
            fromFile: fileURL,
            delegate: connectivityDelegate
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
    
    func uploadFinalVariants(
        _ variants: GeneratedFinalVariants,
        to photoID: String
    ) async throws -> FinalVariantUploadResponse {
        try await uploadImageVariants(
            variants,
            sourceKind: .final,
            to: photoID
        )
    }
    
    func uploadImageVariants(
        _ variants: GeneratedFinalVariants,
        sourceKind:
        ServerPhotoVariantSourceKind,
        to photoID: String,
        connectivityCallbacks:
        UploadConnectivityCallbacks? = nil
    ) async throws -> FinalVariantUploadResponse {
        let multipartBody =
        try MultipartFormFileService
            .createImageVariantsBody(
                photoID: photoID,
                variants: variants
            )
        
        defer {
            try? MultipartFormFileService.remove(
                multipartBody
            )
        }
        
        let url = baseURL
            .appending(path: "api")
            .appending(path: "admin")
            .appending(path: "photos")
            .appending(path: photoID)
            .appending(path: "variants")
            .appending(path: sourceKind.rawValue)
        
        var request = URLRequest(url: url)
        
        request.httpMethod = "PUT"
        request.timeoutInterval = 300
        
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        
        request.setValue(
        """
        multipart/form-data; \
        boundary=\(multipartBody.boundary)
        """,
        forHTTPHeaderField:
            "Content-Type"
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
        
        let connectivityDelegate =
        connectivityCallbacks.map { callbacks in
            UploadConnectivityTaskDelegate(
                callbacks: callbacks
            )
        }

        let (data, response) =
        try await uploadSession.upload(
            for: request,
            fromFile:
                multipartBody.fileURL,
            delegate: connectivityDelegate
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
        
        guard contentType.contains(
            "application/json"
        ) else {
            throw APIClientError.unexpectedResponse
        }
        
        do {
            return try makeDecoder().decode(
                FinalVariantUploadResponse.self,
                from: data
            )
        } catch {
            print(
                "Image variant decoding failed:",
                error
            )
            
            throw APIClientError
                .invalidFinalVariantUploadResponse
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
    
    func setPhotoWorkflowStatus(
        _ status: ServerPhotoWorkflowStatus,
        for photoID: String
    ) async throws -> PhotoWorkflowResponse {
        let url = baseURL
            .appending(path: "api")
            .appending(path: "admin")
            .appending(path: "photos")
            .appending(path: photoID)
            .appending(path: "workflow")
        
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
        
        request.httpBody = try JSONEncoder().encode(
            SetPhotoWorkflowRequest(
                status: status.rawValue
            )
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
        
        guard
            contentType.contains(
                "application/json"
            )
        else {
            throw APIClientError.unexpectedResponse
        }
        
        do {
            return try makeDecoder().decode(
                PhotoWorkflowResponse.self,
                from: data
            )
        } catch {
            print(
                "Photo workflow decoding failed:",
                error
            )
            
            throw APIClientError
                .invalidPhotoWorkflowResponse
        }
    }
    
    private func makeAdminJSONRequest(
        url: URL
    ) -> URLRequest {
        var request = URLRequest(url: url)
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
        
        return request
    }
    
    private func performEventMutation(
        _ request: URLRequest
    ) async throws -> PickPicEvent {
        let (data, response) =
        try await session.data(
            for: request
        )
        
        try validateJSONResponse(
            data: data,
            response: response
        )
        
        do {
            return try makeDecoder().decode(
                EventResponse.self,
                from: data
            )
            .event
        } catch {
            print(
                "Event mutation decoding failed:",
                error
            )
            
            throw APIClientError
                .invalidEventMutationResponse
        }
    }
    
    private func validateJSONResponse(
        data: Data,
        response: URLResponse
    ) throws {
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
