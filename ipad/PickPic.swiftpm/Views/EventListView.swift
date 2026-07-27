import SwiftUI

struct EventListView: View {
    let events: [PickPicEvent]
    let isLoading: Bool
    let errorMessage: String?
    
    let onRefresh: () async -> Void
    let onCreateEvent:
    (String) async throws -> Void
    
    let onEventUpdated:
    (PickPicEvent) -> Void
    
    let onEventDeleted:
    (String) -> Void
    
    @EnvironmentObject private var uploadQueue:
    UploadQueueStore
    
    @State private var showingCreateEvent = false
    
    var body: some View {
        List {
            if
                let errorMessage,
                !events.isEmpty
            {
                Section {
                    VStack(
                        alignment: .leading,
                        spacing: 10
                    ) {
                        Label(
                            "Unable to Refresh",
                            systemImage:
                                "exclamationmark.triangle"
                        )
                        .font(.headline)
                        
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Button("Try Again") {
                            Task {
                                await onRefresh()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            ForEach(events) { event in
                NavigationLink(value: event) {
                    let jobs = uploadQueue.jobs(
                        for: event.id
                    )
                    
                    EventRow(
                        event: event,
                        unfinishedJobCount:
                            jobs.filter { job in
                                job.stage != .completed
                            }
                            .count,
                        activeJobCount:
                            jobs.filter { job in
                                switch job.stage {
                                case .preparing,
                                        .converting,
                                        .uploading:
                                    return true
                                    
                                case .queued,
                                        .prepared,
                                        .readyToUpload,
                                        .completed,
                                        .failed:
                                    return false
                                }
                            }
                            .count
                    )
                }
            }
        }
        .navigationTitle("Events")
        .navigationDestination(
            for: PickPicEvent.self
        ) { event in
            EventDetailView(
                event: event,
                onEventUpdated:
                    onEventUpdated,
                onEventDeleted:
                    onEventDeleted
            )
        }
        .refreshable {
            await onRefresh()
        }
        .toolbar {
            ToolbarItem(
                placement: .topBarTrailing
            ) {
                Button {
                    showingCreateEvent = true
                } label: {
                    Label(
                        "New Event",
                        systemImage: "plus"
                    )
                }
            }
        }
        .sheet(
            isPresented: $showingCreateEvent
        ) {
            EventTitleEditorView(
                navigationTitle: "New Event",
                saveButtonTitle: "Create",
                onSave: onCreateEvent
            )
        }
        .overlay {
            if events.isEmpty {
                emptyState
            }
        }
    }
    
    @ViewBuilder
    private var emptyState: some View {
        if isLoading {
            ProgressView(
                "Loading events…"
            )
        } else if let errorMessage {
            ContentUnavailableView {
                Label(
                    "Unable to Load Events",
                    systemImage:
                        "exclamationmark.triangle"
                )
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task {
                        await onRefresh()
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label(
                    "No Events",
                    systemImage:
                        "photo.on.rectangle.angled"
                )
            } description: {
                Text(
                    """
                    Create an event to start importing and \
                    sharing photos.
                    """
                )
            } actions: {
                Button("Create Event") {
                    showingCreateEvent = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct EventRow: View {
    let event: PickPicEvent
    let unfinishedJobCount: Int
    let activeJobCount: Int
    
    private var uploadStatusText: String {
        if activeJobCount > 0 {
            return activeJobCount == 1
            ? "Upload in progress"
            : "\(activeJobCount) uploads in progress"
        }
        
        return unfinishedJobCount == 1
        ? "1 upload to continue"
        : "\(unfinishedJobCount) uploads to continue"
    }
    
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.title2)
                .frame(
                    width: 36,
                    height: 36
                )
                .foregroundStyle(.tint)
            
            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                Text(event.title)
                    .font(.headline)
                
                Label(
                    event.status.title,
                    systemImage:
                        event.status.systemImage
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                
                if unfinishedJobCount > 0 {
                    Label(
                        uploadStatusText,
                        systemImage:
                            activeJobCount > 0
                        ? "arrow.up.circle.fill"
                        : "clock.arrow.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        activeJobCount > 0
                        ? Color.accentColor
                        : Color.orange
                    )
                }
            }
            
            Spacer()
            
            Text(
                event.updatedAt.formatted(
                    date: .abbreviated,
                    time: .omitted
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
