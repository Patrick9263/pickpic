import Combine
import Foundation

private enum PublishGalleryError:
    LocalizedError
{
    case noPhotos
    
    var errorDescription: String? {
        switch self {
        case .noPhotos:
            return """
            Upload at least one photo before publishing \
            this gallery.
            """
        }
    }
}

@MainActor
final class PublishGalleryViewModel:
    ObservableObject
{
    @Published private(set)
    var serverPhotoCount: Int?
    
    @Published private(set)
    var isLoading = false
    
    @Published private(set)
    var isPublishing = false
    
    @Published private(set)
    var errorMessage: String?
    
    func load(
        eventID: String,
        using configuration:
        APIConfigurationStore
    ) async {
        guard !isLoading else {
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        defer {
            isLoading = false
        }
        
        do {
            let client =
            try configuration.makeClient()
            
            serverPhotoCount =
            try await client
                .fetchEventPhotoCount(
                    eventID: eventID
                )
        } catch {
            errorMessage =
            error.localizedDescription
        }
    }
    
    func publish(
        event: PickPicEvent,
        using configuration:
        APIConfigurationStore
    ) async -> PickPicEvent? {
        guard !isPublishing else {
            return nil
        }
        
        isPublishing = true
        errorMessage = nil
        
        defer {
            isPublishing = false
        }
        
        do {
            let client =
            try configuration.makeClient()
            
            let photoCount =
            try await client
                .fetchEventPhotoCount(
                    eventID: event.id
                )
            
            serverPhotoCount = photoCount
            
            guard photoCount > 0 else {
                throw PublishGalleryError.noPhotos
            }
            
            return try await client.setEventStatus(
                .ready,
                for: event.id
            )
        } catch {
            errorMessage =
            error.localizedDescription
            
            return nil
        }
    }
}
