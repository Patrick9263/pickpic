import SwiftUI

struct EventListView: View {
    let events: [PickPicEvent]
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () async -> Void
    
    var body: some View {
        List(events) { event in
            NavigationLink(value: event) {
                EventRow(event: event)
            }
        }
        .navigationTitle("Events")
        .navigationDestination(for: PickPicEvent.self) { event in
            EventDetailView(event: event)
        }
        .refreshable {
            await onRefresh()
        }
        .overlay {
            if isLoading && events.isEmpty {
                ProgressView("Loading events…")
            } else if let errorMessage, events.isEmpty {
                ContentUnavailableView {
                    Label(
                        "Unable to Load Events",
                        systemImage: "exclamationmark.triangle"
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
            } else if events.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(
                        "Your PickPic events will appear here."
                    )
                )
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
                .frame(width: 36, height: 36)
                .foregroundStyle(.tint)
            
            VStack(alignment: .leading, spacing: 5) {
                Text(event.title)
                    .font(.headline)
                
                Label(
                    event.status.title,
                    systemImage: event.status.systemImage
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
