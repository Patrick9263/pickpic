import SwiftUI

struct ContentView: View {
    @StateObject private var configuration =
    APIConfigurationStore()
    
    @StateObject private var viewModel =
    EventListViewModel()
    
    @State private var showingSettings = false
    
    var body: some View {
        NavigationStack {
            EventListView(
                events: viewModel.events,
                isLoading: viewModel.isLoading,
                errorMessage: viewModel.errorMessage
            ) {
                await viewModel.load(using: configuration)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label(
                            "Connection Settings",
                            systemImage: "gearshape"
                        )
                    }
                }
            }
        }
        .environmentObject(configuration)
        .sheet(isPresented: $showingSettings) {
            ConnectionSettingsView(
                configuration: configuration
            )
        }
        .task(id: configuration.revision) {
            if !configuration.isConfigured {
                showingSettings = true
            }
            
            await viewModel.load(using: configuration)
        }
    }
}
