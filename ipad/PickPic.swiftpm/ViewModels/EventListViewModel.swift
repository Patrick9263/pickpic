import Combine
import Foundation

@MainActor
final class EventListViewModel:
    ObservableObject
{
    @Published private(set)
    var events: [PickPicEvent] = []
    
    @Published private(set)
    var isLoading = false
    
    @Published private(set)
    var errorMessage: String?
    
    func load(
        using configuration:
        APIConfigurationStore
    ) async {
        guard !isLoading else {
            return
        }
        
        guard configuration.isConfigured else {
            events = []
            
            errorMessage =
                """
                Open Connection Settings to connect \
                to PickPic.
                """
            
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
            
            events =
            try await client.fetchEvents()
        } catch {
            errorMessage =
            error.localizedDescription
        }
    }
    
    func createEvent(
        title: String,
        using configuration:
        APIConfigurationStore
    ) async throws {
        let client =
        try configuration.makeClient()
        
        let createdEvent =
        try await client.createEvent(
            title: title
        )
        
        events.removeAll { event in
            event.id == createdEvent.id
        }
        
        events.insert(
            createdEvent,
            at: 0
        )
        
        errorMessage = nil
    }
    
    func replaceEvent(
        _ updatedEvent: PickPicEvent
    ) {
        guard
            let index = events.firstIndex(
                where: { event in
                    event.id == updatedEvent.id
                }
            )
        else {
            return
        }
        
        events[index] = updatedEvent
    }
    
    func removeEvent(
        eventID: String
    ) {
        events.removeAll { event in
            event.id == eventID
        }
    }
}
