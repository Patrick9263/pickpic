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
                    EventRow(event: event)
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
