import SwiftUI

struct ConnectionSettingsView: View {
    @ObservedObject var configuration: APIConfigurationStore
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var errorMessage: String?
    @State private var loadedExistingValues = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("PickPic Server") {
                    Text(
                        APIConfigurationStore
                            .productionBaseURL
                            .absoluteString
                    )
                    .font(.footnote)
                    .textSelection(.enabled)
                }
                
                Section("Cloudflare Access") {
                    TextField(
                        "Client ID",
                        text: $clientID
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    
                    SecureField(
                        "Client Secret",
                        text: $clientSecret
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                
                Section {
                    Text(
                        """
                        These credentials are stored in the iPad Keychain. \
                        They are not added to the Git repository.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                
                if let errorMessage {
                    Section {
                        Label(
                            errorMessage,
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connection Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                }
            }
            .onAppear {
                guard !loadedExistingValues else {
                    return
                }
                
                clientID = configuration.clientID
                clientSecret = configuration.clientSecret
                loadedExistingValues = true
            }
        }
    }
    
    private func save() {
        do {
            try configuration.save(
                clientID: clientID,
                clientSecret: clientSecret
            )
            
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
