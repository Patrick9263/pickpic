import Combine
import Foundation

enum APIConfigurationError: LocalizedError {
    case missingCredentials
    
    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Enter both the Cloudflare Client ID and Client Secret."
        }
    }
}

@MainActor
final class APIConfigurationStore: ObservableObject {
    private enum Account {
        static let clientID = "cloudflare-client-id"
        static let clientSecret = "cloudflare-client-secret"
    }
    
    static let productionBaseURL = URL(
        string: "https://pickpic-admin.maverickthedeer.workers.dev"
    )!
    
    @Published private(set) var clientID: String
    @Published private(set) var clientSecret: String
    @Published private(set) var revision = 0
    
    init() {
        clientID =
        (try? KeychainStore.string(for: Account.clientID))
        ?? ""
        
        clientSecret =
        (try? KeychainStore.string(for: Account.clientSecret))
        ?? ""
    }
    
    var isConfigured: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty
    }
    
    func save(
        clientID: String,
        clientSecret: String
    ) throws {
        let trimmedClientID = clientID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        
        let trimmedClientSecret =
        clientSecret.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        
        guard
            !trimmedClientID.isEmpty,
            !trimmedClientSecret.isEmpty
        else {
            throw APIConfigurationError.missingCredentials
        }
        
        try KeychainStore.set(
            trimmedClientID,
            for: Account.clientID
        )
        
        try KeychainStore.set(
            trimmedClientSecret,
            for: Account.clientSecret
        )
        
        self.clientID = trimmedClientID
        self.clientSecret = trimmedClientSecret
        revision += 1
    }
    
    func makeClient() throws -> APIClient {
        guard isConfigured else {
            throw APIClientError.notConfigured
        }
        
        return APIClient(
            baseURL: Self.productionBaseURL,
            clientID: clientID,
            clientSecret: clientSecret
        )
    }
}
