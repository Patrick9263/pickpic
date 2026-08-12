import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var configuration:
    APIConfigurationStore

    @EnvironmentObject private var feedback:
    AppFeedbackStore

    @EnvironmentObject private var uploadQueue:
    UploadQueueStore

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
            .onReceive(uploadQueue.$jobs) { jobs in
                /*
                 * A run only starts once the event has been created on
                 * the server, so a started upload is proof the event is
                 * no longer local-only. Reading startedAt rather than
                 * the stage keeps this correct if the stage list grows.
                 */
                viewModel.markEventsCreatedRemotely(
                    Set(
                        jobs.compactMap { job in
                            job.uploadProgress.startedAt == nil
                            ? nil
                            : job.eventID
                        }
                    )
                )
            }
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
        .overlay(alignment: .top) {
            if let message = feedback.message {
                AppFeedbackBanner(
                    message: message,
                    onDismiss: {
                        feedback.dismiss()
                    }
                )
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                )
                .zIndex(10)
            }
        }
        .animation(
            .snappy,
            value: feedback.message?.id
        )
    }
}

private struct AppFeedbackBanner: View {
    let message: AppFeedbackMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(
                systemName:
                    message.systemImage
            )
            .font(.title3)
            .foregroundStyle(.green)

            VStack(
                alignment: .leading,
                spacing: 2
            ) {
                Text(message.title)
                    .font(.headline)

                Text(message.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 8)

            Button {
                onDismiss()
            } label: {
                Image(
                    systemName: "xmark"
                )
                .font(.caption.weight(.bold))
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
            .stroke(.quaternary)
        }
        .shadow(radius: 8, y: 4)
        .onTapGesture {
            onDismiss()
        }
    }
}
