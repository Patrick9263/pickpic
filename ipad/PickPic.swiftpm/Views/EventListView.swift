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

import SwiftUI

struct EventTitleEditorView: View {
    let navigationTitle: String
    let saveButtonTitle: String
    let unchangedTitle: String?
    let onSave: (String) async throws -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var title: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    init(
        navigationTitle: String,
        saveButtonTitle: String,
        initialTitle: String = "",
        unchangedTitle: String? = nil,
        onSave:
        @escaping (String) async throws -> Void
    ) {
        self.navigationTitle = navigationTitle
        self.saveButtonTitle = saveButtonTitle
        self.unchangedTitle = unchangedTitle
        self.onSave = onSave
        
        _title = State(
            initialValue: initialTitle
        )
    }
    
    private var trimmedTitle: String {
        title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
    
    private var isUnchanged: Bool {
        guard let unchangedTitle else {
            return false
        }
        
        return trimmedTitle == unchangedTitle
    }
    
    private var canSave: Bool {
        !isSaving
        && !trimmedTitle.isEmpty
        && trimmedTitle.count <= 120
        && !isUnchanged
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField(
                        "Event name",
                        text: $title
                    )
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit {
                        save()
                    }
                    
                    HStack {
                        Text(
                            "Use a clear name you will recognize later."
                        )
                        
                        Spacer()
                        
                        Text("\(trimmedTitle.count)/120")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(
                        trimmedTitle.count > 120
                        ? Color.red
                        : Color.secondary
                    )
                }
                
                if let errorMessage {
                    Section {
                        Label(
                            errorMessage,
                            systemImage:
                                "exclamationmark.triangle"
                        )
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                
                ToolbarItem(
                    placement: .confirmationAction
                ) {
                    Button(saveButtonTitle) {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .overlay {
                if isSaving {
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 16,
                                style: .continuous
                            )
                        )
                }
            }
        }
    }
    
    private func save() {
        guard canSave else {
            return
        }
        
        let titleToSave = trimmedTitle
        
        Task {
            isSaving = true
            errorMessage = nil
            
            defer {
                isSaving = false
            }
            
            do {
                try await onSave(titleToSave)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
