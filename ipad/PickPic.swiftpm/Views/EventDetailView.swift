import SwiftUI

struct EventDetailView: View {
    @State private var event:
    PickPicEvent
    
    let onEventUpdated:
    (PickPicEvent) -> Void
    
    let onEventDeleted:
    (String) -> Void
    
    @EnvironmentObject private var configuration:
    APIConfigurationStore
    
    @EnvironmentObject private var uploadQueue:
    UploadQueueStore
    
    @EnvironmentObject private var eventFolders:
    EventFolderStore
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingRenameEvent = false
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    
    @State private var showingDeleteError = false
    @State private var deleteErrorMessage = ""
    
    init(
        event: PickPicEvent,
        onEventUpdated:
        @escaping (PickPicEvent) -> Void,
        onEventDeleted:
        @escaping (String) -> Void
    ) {
        _event = State(
            initialValue: event
        )
        
        self.onEventUpdated =
        onEventUpdated
        
        self.onEventDeleted =
        onEventDeleted
    }
    
    private var eventJobs: [UploadJob] {
        uploadQueue.jobs(
            for: event.id
        )
    }
    
    private var eventHasActiveProcessing: Bool {
        eventJobs.contains { job in
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
    }
    
    var body: some View {
        List {
            Section("Event") {
                LabeledContent(
                    "Name",
                    value: event.title
                )
                
                LabeledContent {
                    Label(
                        event.status.title,
                        systemImage:
                            event.status.systemImage
                    )
                } label: {
                    Text("Status")
                }
                
                LabeledContent(
                    "Created",
                    value:
                        event.createdAt.formatted(
                            date: .long,
                            time: .shortened
                        )
                )
                
                LabeledContent(
                    "Updated",
                    value:
                        event.updatedAt.formatted(
                            date: .long,
                            time: .shortened
                        )
                )
            }
            
            Section("Photos") {
                NavigationLink {
                    PhotoImportView(
                        event: event
                    )
                } label: {
                    Label(
                        "Import Photos",
                        systemImage:
                            "photo.badge.plus"
                    )
                }
                
                NavigationLink {
                    UploadQueueView(
                        event: event
                    )
                } label: {
                    Label(
                        "Upload Queue",
                        systemImage:
                            "arrow.up.circle"
                    )
                }
                
                NavigationLink {
                    LikedPhotosView(event: event)
                } label: {
                    Label(
                        "Liked Photos",
                        systemImage: "heart.fill"
                    )
                }
                
                NavigationLink {
                    FinalUploadsView(event: event)
                } label: {
                    Label(
                        "Upload Finals",
                        systemImage:
                            "arrow.up.circle.fill"
                    )
                }
            }
            
            Section("Gallery") {
                NavigationLink {
                    PublishGalleryView(
                        event: event
                    ) { updatedEvent in
                        event = updatedEvent
                        
                        onEventUpdated(
                            updatedEvent
                        )
                    }
                } label: {
                    Label(
                        "Publish & Share",
                        systemImage:
                            "square.and.arrow.up"
                    )
                }
            }
            
            Section {
                Button {
                    showingRenameEvent = true
                } label: {
                    Label(
                        "Rename Event",
                        systemImage: "pencil"
                    )
                }
                .disabled(isDeleting)
                
                Button(
                    role: .destructive
                ) {
                    showingDeleteConfirmation = true
                } label: {
                    Label(
                        "Delete Event",
                        systemImage: "trash"
                    )
                }
                .disabled(
                    isDeleting
                    || eventHasActiveProcessing
                )
                
                if eventHasActiveProcessing {
                    Text(
                        """
                        Finish the current preparation, conversion, \
                        or upload before deleting this event.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Manage Event")
            } footer: {
                Text(
                    """
                    Deleting an event permanently removes its online \
                    gallery and uploaded images. Your original event \
                    folder, To Edit, and Edited folders are not changed.
                    """
                )
            }
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isDeleting)
        .overlay {
            if isDeleting {
                ProgressView(
                    "Deleting event…"
                )
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
        .sheet(
            isPresented: $showingRenameEvent
        ) {
            EventTitleEditorView(
                navigationTitle: "Rename Event",
                saveButtonTitle: "Save",
                initialTitle: event.title,
                unchangedTitle: event.title
            ) { title in
                let client =
                try configuration.makeClient()
                
                let updatedEvent =
                try await client.updateEvent(
                    title: title,
                    eventID: event.id
                )
                
                event = updatedEvent
                onEventUpdated(updatedEvent)
            }
        }
        .alert(
            "Delete \(event.title)?",
            isPresented:
                $showingDeleteConfirmation
        ) {
            Button(
                "Delete Event",
                role: .destructive
            ) {
                Task {
                    await deleteEvent()
                }
            }
            
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                This permanently deletes the online gallery, uploaded \
                photos, finals, comments, and likes. This cannot be undone.
                """
            )
        }
        .alert(
            "Unable to Delete Event",
            isPresented: $showingDeleteError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
    }
    
    private func deleteEvent() async {
        guard !eventHasActiveProcessing else {
            deleteErrorMessage =
                """
                Finish the current preparation, conversion, or \
                upload before deleting this event.
                """
            
            showingDeleteError = true
            return
        }
        
        isDeleting = true
        
        defer {
            isDeleting = false
        }
        
        do {
            let client =
            try configuration.makeClient()
            
            try await client.deleteEvent(
                eventID: event.id
            )
            
            let jobIDs = Set(
                eventJobs.map(\.id)
            )
            
            if !jobIDs.isEmpty {
                do {
                    try uploadQueue.remove(
                        jobIDs: jobIDs
                    )
                } catch {
                    print(
                        "Event deleted, but local upload jobs could not be removed:",
                        error
                    )
                }
            }
            
            if eventFolders.reference(
                for: event.id
            ) != nil {
                do {
                    try eventFolders.removeReference(
                        for: event.id
                    )
                } catch {
                    print(
                        "Event deleted, but its saved folder reference could not be removed:",
                        error
                    )
                }
            }
            
            onEventDeleted(event.id)
            dismiss()
        } catch {
            deleteErrorMessage =
            error.localizedDescription
            
            showingDeleteError = true
        }
    }
}
