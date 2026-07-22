import Combine
import Foundation

@MainActor
final class EventListViewModel: ObservableObject {
    @Published private(set) var events: [PickPicEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    
    func load(
        using configuration: APIConfigurationStore
    ) async {
        guard !isLoading else {
            return
        }
        
        guard configuration.isConfigured else {
            events = []
            errorMessage =
            "Open Connection Settings to connect to PickPic."
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        defer {
            isLoading = false
        }
        
        do {
            let client = try configuration.makeClient()
            events = try await client.fetchEvents()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
