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
    
    @State private var isUpdatingStatus = false
    @State private var showingArchiveConfirmation = false
    @State private var showingStatusError = false
    @State private var statusErrorMessage = ""
    @State private var showingGalleryStatusPicker = false
    
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
    
    private var unfinishedEventJobCount: Int {
        eventJobs.filter { job in
            job.stage != .completed
        }
        .count
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
    
    private var displayedGalleryStatus:
    PickPicEvent.Status
    {
        switch event.status {
        case .ready,
                .completed,
                .archived:
            return event.status
            
        case .draft,
                .uploading,
                .editing:
            return .draft
        }
    }
    
    private var galleryStatusTitle: String {
        switch displayedGalleryStatus {
        case .draft:
            return "Draft"
            
        case .ready:
            return "Open"
            
        case .completed:
            return "Closed"
            
        case .archived:
            return "Archived"
            
        case .uploading,
                .editing:
            return "Draft"
        }
    }
    
    private var selectableGalleryStatuses:
    [PickPicEvent.Status]
    {
        [
            .draft,
            .ready,
            .completed,
            .archived
        ]
    }
    
    var body: some View {
        List {
            Section("Event") {
                galleryStatusMenu
                
                LabeledContent(
                    "Created",
                    value:
                        event.createdAt.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                )
                
                LabeledContent(
                    "Updated",
                    value:
                        event.updatedAt.formatted(
                            date: .abbreviated,
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
                        eventJobs.isEmpty
                        ? "Import Photos"
                        : "Add More Photos",
                        systemImage:
                            "photo.badge.plus"
                    )
                }
                
                NavigationLink {
                    UploadQueueView(
                        event: event
                    )
                } label: {
                    HStack {
                        Label(
                            unfinishedEventJobCount > 0
                            ? "Continue Upload"
                            : "Upload Queue",
                            systemImage:
                                unfinishedEventJobCount > 0
                            ? "clock.arrow.circlepath"
                            : "arrow.up.circle"
                        )
                        
                        Spacer()
                        
                        if unfinishedEventJobCount > 0 {
                            Text(
                                "\(unfinishedEventJobCount)"
                            )
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        }
                    }
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
                .disabled(
                    isDeleting
                    || isUpdatingStatus
                )
                
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
                    || isUpdatingStatus
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
            "Archive \(event.title)?",
            isPresented:
                $showingArchiveConfirmation
        ) {
            Button(
                "Archive Event",
                role: .destructive
            ) {
                Task {
                    await updateGalleryStatus(
                        .archived
                    )
                }
            }
            
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                Archiving makes the public gallery unavailable. You can \
                restore it later by changing the status to Open or Closed.
                """
            )
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
            "Unable to Change Status",
            isPresented: $showingStatusError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statusErrorMessage)
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
    
    private var galleryStatusMenu: some View {
        LabeledContent {
            Button {
                showingGalleryStatusPicker = true
            } label: {
                HStack(spacing: 6) {
                    if isUpdatingStatus {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(
                            systemName:
                                gallerySystemImage(
                                    for:
                                        displayedGalleryStatus
                                )
                        )

                        Text(galleryStatusTitle)

                        Image(
                            systemName: "chevron.down"
                        )
                        .font(.caption2.weight(.semibold))
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    .thinMaterial,
                    in: Capsule()
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(
                isDeleting
                || isUpdatingStatus
                || eventHasActiveProcessing
            )
            .popover(
                isPresented:
                    $showingGalleryStatusPicker,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                VStack(spacing: 0) {
                    Text("Gallery Status")
                        .font(.headline)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    Divider()

                    ForEach(
                        selectableGalleryStatuses,
                        id: \.self
                    ) { status in
                        Button {
                            showingGalleryStatusPicker = false

                            requestGalleryStatus(
                                status
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Image(
                                    systemName:
                                        gallerySystemImage(
                                            for: status
                                        )
                                )
                                .frame(width: 20)

                                Text(
                                    galleryTitle(
                                        for: status
                                    )
                                )

                                Spacer()

                                if status
                                    == displayedGalleryStatus
                                {
                                    Image(
                                        systemName: "checkmark"
                                    )
                                    .font(.body.weight(.semibold))
                                }
                            }
                            .foregroundStyle(
                                status
                                    == displayedGalleryStatus
                                ? .secondary
                                : .primary
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            status
                            == displayedGalleryStatus
                        )
                    }
                }
                .frame(minWidth: 220)
                .padding(.vertical, 4)
                .presentationCompactAdaptation(
                    .popover
                )
            }
        } label: {
            Text("Gallery Status")
        }
    }

    private func galleryTitle(
        for status: PickPicEvent.Status
    ) -> String {
        switch status {
        case .draft:
            return "Draft"
            
        case .ready:
            return "Open"
            
        case .completed:
            return "Closed"
            
        case .archived:
            return "Archived"
            
        case .uploading,
                .editing:
            return "Draft"
        }
    }
    
    private func gallerySystemImage(
        for status: PickPicEvent.Status
    ) -> String {
        switch status {
        case .draft,
                .uploading,
                .editing:
            return "pencil"
            
        case .ready:
            return "globe"
            
        case .completed:
            return "checkmark.circle"
            
        case .archived:
            return "archivebox"
        }
    }
    
    private func requestGalleryStatus(
        _ status: PickPicEvent.Status
    ) {
        guard
            status != displayedGalleryStatus,
            !isUpdatingStatus,
            !eventHasActiveProcessing
        else {
            return
        }
        
        if status == .archived {
            showingArchiveConfirmation = true
            return
        }
        
        Task {
            await updateGalleryStatus(
                status
            )
        }
    }
    
    private func updateGalleryStatus(
        _ status: PickPicEvent.Status
    ) async {
        guard !isUpdatingStatus else {
            return
        }
        
        isUpdatingStatus = true
        
        defer {
            isUpdatingStatus = false
        }
        
        do {
            let client =
            try configuration.makeClient()
            
            let updatedEvent =
            try await client.setEventStatus(
                status,
                for: event.id
            )
            
            event = updatedEvent
            onEventUpdated(updatedEvent)
        } catch {
            statusErrorMessage =
            error.localizedDescription
            
            showingStatusError = true
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
