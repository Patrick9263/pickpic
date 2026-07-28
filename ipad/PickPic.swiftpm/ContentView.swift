import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var configuration:
    APIConfigurationStore
    
    @StateObject private var viewModel =
    EventListViewModel()
    
    @State private var showingSettings = false
    
    var body: some View {
        NavigationStack {
            EventListView(
                events: viewModel.events,
                statisticsByEventID:
                    viewModel.statisticsByEventID,
                statisticsFailedEventIDs:
                    viewModel.statisticsFailedEventIDs,
                isLoading:
                    viewModel.isLoading,
                isLoadingStatistics:
                    viewModel.isLoadingStatistics,
                errorMessage:
                    viewModel.errorMessage,
                onRefresh: {
                    await viewModel.load(
                        using: configuration
                    )
                },
                onCreateEvent: { title in
                    try await viewModel.createEvent(
                        title: title,
                        using: configuration
                    )
                },
                onEventUpdated: {
                    updatedEvent in
                    
                    viewModel.replaceEvent(
                        updatedEvent
                    )
                },
                onEventStatisticsUpdated: {
                    eventID, statistics in

                    viewModel.replaceStatistics(
                        statistics,
                        for: eventID
                    )
                },
                onEventDeleted: { eventID in
                    viewModel.removeEvent(
                        eventID: eventID
                    )
                }
            )
            .toolbar {
                ToolbarItem(
                    placement: .topBarTrailing
                ) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label(
                            "Connection Settings",
                            systemImage:
                                "gearshape"
                        )
                    }
                }
            }
        }
        .environmentObject(configuration)
        .sheet(
            isPresented: $showingSettings
        ) {
            ConnectionSettingsView(
                configuration:
                    configuration
            )
        }
        .task(id: configuration.revision) {
            if !configuration.isConfigured {
                showingSettings = true
            }
            
            await viewModel.load(
                using: configuration
            )
        }
    }
}
