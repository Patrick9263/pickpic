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

    /*
     * Selection is held by id rather than by event, because an event
     * changes identity whenever its status or title updates and a
     * value-based selection would be dropped underneath the detail.
     */
    @State private var selectedEventID: String?

    /*
     * With nothing selected the detail column would otherwise be a large
     * empty area, so it carries the all-events summary that used to sit
     * at the top of the sidebar crowding out the events themselves.
     */
    @ViewBuilder
    private var placeholder: some View {
        if viewModel.events.isEmpty {
            ContentUnavailableView(
                "No Event Selected",
                systemImage:
                    "photo.on.rectangle.angled",
                description: Text(
                    "Create an event to start importing and sharing photos."
                )
            )
        } else {
            List {
                Section {
                    EventOverview(
                        eventCount:
                            viewModel.events.count,
                        statistics:
                            EventPhotoStatistics.total(
                                for: viewModel.events,
                                statisticsByEventID:
                                    viewModel
                                    .statisticsByEventID
                            ),
                        incompleteJobCount:
                            viewModel.events.reduce(
                                0
                            ) { total, event in
                                total
                                + uploadQueue.jobs(
                                    for: event.id
                                )
                                .filter { job in
                                    job.stage
                                        != .completed
                                }
                                .count
                            },
                        showsPlaceholder:
                            !allStatisticsAreLoaded
                    )
                } header: {
                    HStack {
                        Text("Overview")

                        Spacer()

                        if viewModel
                            .isLoadingStatistics {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                } footer: {
                    Text(
                        "Choose an event to import photos, review likes, and publish its gallery."
                    )
                }

                StorageUsagePanel()
            }
            .navigationTitle("All Events")
        }
    }

    private var allStatisticsAreLoaded: Bool {
        !viewModel.events.isEmpty
        && viewModel.events.allSatisfy { event in
            viewModel.statisticsByEventID[event.id]
                != nil
            && !viewModel.statisticsFailedEventIDs
                .contains(event.id)
        }
    }

    private var selectedEvent: PickPicEvent? {
        guard let selectedEventID else {
            return nil
        }

        return viewModel.events.first { event in
            event.id == selectedEventID
        }
    }

    var body: some View {
        NavigationSplitView {
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
                selectedEventID: $selectedEventID,
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
        } detail: {
            /*
             * The detail column carries its own stack, because an event
             * pushes onward to import, queue, liked photos and finals.
             */
            NavigationStack {
                if let selectedEvent {
                    EventDetailView(
                        event: selectedEvent,
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

                            /*
                             * Nothing would clear this otherwise, and
                             * the detail would keep showing an event
                             * that no longer exists.
                             */
                            if selectedEventID == eventID {
                                selectedEventID = nil
                            }
                        }
                    )
                    /*
                     * Ties the view's identity to the event so that
                     * picking a different one rebuilds it. Without this
                     * the detail keeps the first event's local state.
                     */
                    .id(selectedEvent.id)
                } else {
                    placeholder
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
