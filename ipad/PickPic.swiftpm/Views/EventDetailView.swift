import SwiftUI

struct EventDetailView: View {
    @State private var event:
    PickPicEvent
    
    let onEventUpdated:
    (PickPicEvent) -> Void

    let onEventStatisticsUpdated:
    (String, EventPhotoStatistics) -> Void
    
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

    @State private var dashboardStatistics:
    EventPhotoStatistics?

    @State private var dashboardReadyFinalCount:
    Int?

    @State private var dashboardToEditFileCount:
    Int?

    @State private var isLoadingDashboard = false
    @State private var dashboardErrorMessage: String?
    @State private var dashboardFolderMessage: String?
    @State private var dashboardLastUpdatedAt: Date?
    
    init(
        event: PickPicEvent,
        onEventUpdated:
        @escaping (PickPicEvent) -> Void,
        onEventStatisticsUpdated:
        @escaping (
            String,
            EventPhotoStatistics
        ) -> Void,
        onEventDeleted:
        @escaping (String) -> Void
    ) {
        _event = State(
            initialValue: event
        )
        
        self.onEventUpdated =
        onEventUpdated

        self.onEventStatisticsUpdated =
        onEventStatisticsUpdated
        
        self.onEventDeleted =
        onEventDeleted
    }
    
    /*
     * The one thing worth doing next, chosen from the event's own state.
     * Everything it can point at stays reachable below; this only saves
     * reading ten rows of equal weight to work out which applies.
     *
     * Ordered by urgency: work already started outranks work available,
     * and anything needing the network outranks publishing.
     */
    private enum PrimaryAction {
        case importPhotos
        case continueUpload
        case uploadReadyFinals
        case reviewLiked
        case publish

        var title: String {
            switch self {
            case .importPhotos:
                return "Import Photos"

            case .continueUpload:
                return "Continue Upload"

            case .uploadReadyFinals:
                return "Upload Ready Finals"

            case .reviewLiked:
                return "Review Liked Photos"

            case .publish:
                return "Publish & Share"
            }
        }

        var systemImage: String {
            switch self {
            case .importPhotos:
                return "photo.badge.plus"

            case .continueUpload:
                return "clock.arrow.circlepath"

            case .uploadReadyFinals:
                return "bolt.circle.fill"

            case .reviewLiked:
                return "heart.fill"

            case .publish:
                return "square.and.arrow.up"
            }
        }

        var reason: String {
            switch self {
            case .importPhotos:
                return "This event has no photos yet."

            case .continueUpload:
                return "This event has uploads that have not finished."

            case .uploadReadyFinals:
                return "Edited files are waiting in the Edited folder."

            case .reviewLiked:
                return "Viewers have asked for edits."

            case .publish:
                return "Proofs are uploaded and the gallery is not open yet."
            }
        }
    }

    private var primaryAction: PrimaryAction? {
        if unfinishedEventJobCount > 0 {
            return .continueUpload
        }

        if eventJobs.isEmpty,
            (dashboardStatistics?.uploadedProofCount ?? 0) == 0 {
            return .importPhotos
        }

        if (dashboardReadyFinalCount ?? 0) > 0 {
            return .uploadReadyFinals
        }

        if (dashboardStatistics?.likedPhotoCount ?? 0) > 0 {
            return .reviewLiked
        }

        /*
         * An event still only on this iPad has nothing to publish, and
         * PublishGalleryView blocks it anyway.
         */
        if event.status == .draft,
            !event.needsRemoteCreation,
            (dashboardStatistics?.uploadedProofCount ?? 0) > 0 {
            return .publish
        }

        return nil
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
                    .preflighting,
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
    
    @ViewBuilder
    private var primaryActionSection: some View {
        if let primaryAction {
            Section {
                NavigationLink {
                    primaryDestination(
                        for: primaryAction
                    )
                } label: {
                    Label(
                        primaryAction.title,
                        systemImage:
                            primaryAction.systemImage
                    )
                    .font(.headline)
                }
                .listRowBackground(
                    Color.accentColor
                )
                .foregroundStyle(.white)
            } footer: {
                Text(primaryAction.reason)
            }
        }
    }

    @ViewBuilder
    private func primaryDestination(
        for action: PrimaryAction
    ) -> some View {
        switch action {
        case .importPhotos:
            PhotoImportView(event: event)

        case .continueUpload:
            UploadQueueView(event: event)

        case .uploadReadyFinals:
            FinalUploadsView(
                event: event,
                automaticallyUploadReadyFinals: true
            )

        case .reviewLiked:
            LikedPhotosView(event: event)

        case .publish:
            PublishGalleryView(
                event: event
            ) { updatedEvent in
                event = updatedEvent

                onEventUpdated(updatedEvent)
            }
        }
    }

    var body: some View {
        List {
            primaryActionSection

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
            
            Section {
                EventDetailDashboard(
                    statistics: dashboardStatistics,
                    readyFinalCount:
                        dashboardReadyFinalCount,
                    toEditFileCount:
                        dashboardToEditFileCount,
                    incompleteUploadCount:
                        unfinishedEventJobCount,
                    isLoading:
                        isLoadingDashboard
                )

                if let dashboardErrorMessage {
                    Label(
                        dashboardErrorMessage,
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if let dashboardFolderMessage {
                    Label(
                        dashboardFolderMessage,
                        systemImage: "folder"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Dashboard")

                    Spacer()

                    if isLoadingDashboard {
                        ProgressView()
                            .controlSize(.mini)
                    } else if let dashboardLastUpdatedAt {
                        Text(
                            dashboardLastUpdatedAt.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                        )
                        .font(.caption2)
                    }
                }
            } footer: {
                Text(
                    "Pull down to refresh server and Edited-folder statistics."
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
                    HStack {
                        Label(
                            "Liked Photos",
                            systemImage: "heart.fill"
                        )

                        Spacer()

                        if let likedCount =
                            dashboardStatistics?
                            .likedPhotoCount,
                            likedCount > 0 {
                            Text("\(likedCount)")
                                .font(.caption.bold())
                                .foregroundStyle(
                                    .secondary
                                )
                        }
                    }
                }
                
                NavigationLink {
                    FinalUploadsView(
                        event: event,
                        automaticallyUploadReadyFinals: true
                    )
                } label: {
                    VStack(
                        alignment: .leading,
                        spacing: 3
                    ) {
                        Label(
                            "Upload Ready Finals",
                            systemImage:
                                "bolt.circle.fill"
                        )

                        Text(
                            "Scans Edited and starts uploading matches."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    FinalUploadsView(event: event)
                } label: {
                    HStack {
                        Label(
                            "Review Finals",
                            systemImage:
                                "photo.stack"
                        )

                        Spacer()

                        if let finalCount =
                            dashboardStatistics?
                            .uploadedFinalCount,
                            finalCount > 0 {
                            Text("\(finalCount)")
                                .font(.caption.bold())
                                .foregroundStyle(
                                    .secondary
                                )
                        }
                    }
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
        .refreshable {
            await loadDashboard()
        }
        .onAppear {
            Task {
                await loadDashboard()
            }
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        /*
         * Renaming is a normal thing to do right after creating an event,
         * but the only other way in is at the bottom of this screen in
         * Manage Event, which means scrolling past everything else to
         * reach a button sitting next to Delete. Delete stays down there.
         */
        .toolbar {
            ToolbarItem(
                placement: .topBarTrailing
            ) {
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
            }
        }
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
                /*
                 * An event still only on this iPad has no record to
                 * update, so renaming it is a local edit. The queued
                 * jobs carry the title that will register the event on
                 * its first upload and have to move with it.
                 */
                guard !event.needsRemoteCreation else {
                    let renamedEvent = PickPicEvent(
                        id: event.id,
                        title: title,
                        shareToken: event.shareToken,
                        status: event.status,
                        createdAt: event.createdAt,
                        updatedAt: Date(),
                        isPendingCreation:
                            event.isPendingCreation
                    )

                    uploadQueue.renameEvent(
                        eventID: event.id,
                        title: title
                    )

                    event = renamedEvent
                    onEventUpdated(renamedEvent)

                    return
                }

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
    
    @MainActor
    private func loadDashboard() async {
        guard
            !isLoadingDashboard,
            configuration.isConfigured
        else {
            return
        }

        isLoadingDashboard = true
        dashboardErrorMessage = nil
        dashboardFolderMessage = nil

        defer {
            isLoadingDashboard = false
        }

        do {
            let client =
            try configuration.makeClient()

            let photos =
            try await client.fetchEventPhotos(
                eventID: event.id
            )

            let statistics =
            EventPhotoStatistics(
                photos: photos
            )

            dashboardStatistics = statistics
            onEventStatisticsUpdated(
                event.id,
                statistics
            )

            dashboardLastUpdatedAt = Date()

            guard let reference =
                eventFolders.reference(
                    for: event.id
                )
            else {
                dashboardReadyFinalCount = nil
                dashboardToEditFileCount = nil
                dashboardFolderMessage =
                    "Folder statistics require a saved event folder."
                return
            }

            var folderMessages: [String] = []

            do {
                dashboardToEditFileCount =
                try await Task.detached(
                    priority: .utility
                ) {
                    try EventDashboardFolderService
                        .countToEditPhotos(
                            reference: reference,
                            photos: photos
                        )
                }
                .value
            } catch {
                dashboardToEditFileCount = nil
                folderMessages.append(
                    "To Edit could not be counted: \(error.localizedDescription)"
                )
            }

            do {
                let scanResult =
                try await Task.detached(
                    priority: .utility
                ) {
                    try EditedFolderService.scan(
                        reference: reference,
                        photos: photos
                    )
                }
                .value

                dashboardReadyFinalCount =
                scanResult.candidates.count
            } catch let folderError as EditedFolderError {
                switch folderError {
                case .editedFolderMissing:
                    dashboardReadyFinalCount = 0

                case .eventFolderUnavailable:
                    dashboardReadyFinalCount = nil
                    folderMessages.append(
                        folderError.localizedDescription
                    )
                }
            } catch {
                dashboardReadyFinalCount = nil
                folderMessages.append(
                    "Ready Finals could not be counted: \(error.localizedDescription)"
                )
            }

            dashboardFolderMessage =
            folderMessages.isEmpty
            ? nil
            : folderMessages.joined(
                separator: " "
            )
        } catch {
            dashboardErrorMessage =
            error.localizedDescription
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

private struct EventDetailDashboard: View {
    let statistics: EventPhotoStatistics?
    let readyFinalCount: Int?
    let toEditFileCount: Int?
    let incompleteUploadCount: Int
    let isLoading: Bool

    private let columns = [
        GridItem(
            .adaptive(minimum: 112),
            spacing: 12
        )
    ]

    var body: some View {
        LazyVGrid(
            columns: columns,
            spacing: 12
        ) {
            EventDetailStatistic(
                title: "Proofs",
                value: value(
                    statistics?.uploadedProofCount
                ),
                systemImage: "photo"
            )

            EventDetailStatistic(
                title: "Liked Photos",
                value: value(
                    statistics?.likedPhotoCount
                ),
                systemImage: "heart.fill"
            )

            EventDetailStatistic(
                title: "In To Edit",
                value: value(
                    toEditFileCount
                ),
                systemImage: "folder.fill"
            )

            EventDetailStatistic(
                title: "Editing",
                value: value(
                    statistics?.editingPhotoCount
                ),
                systemImage:
                    "slider.horizontal.3"
            )

            EventDetailStatistic(
                title: "Ready Finals",
                value: value(
                    readyFinalCount
                ),
                systemImage:
                    "bolt.circle.fill"
            )

            EventDetailStatistic(
                title: "Uploaded Finals",
                value: value(
                    statistics?.uploadedFinalCount
                ),
                systemImage:
                    "checkmark.seal.fill"
            )

            EventDetailStatistic(
                title: "Needs Web Versions",
                value: value(
                    statistics?
                        .missingVariantPhotoCount
                ),
                systemImage:
                    "exclamationmark.triangle"
            )

            EventDetailStatistic(
                title: "Uploads to Continue",
                value:
                    "\(incompleteUploadCount)",
                systemImage:
                    "clock.arrow.circlepath"
            )
        }
        .padding(.vertical, 8)
    }

    private func value(
        _ value: Int?
    ) -> String {
        guard let value else {
            return isLoading ? "…" : "—"
        }

        return "\(value)"
    }
}

private struct EventDetailStatistic: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.tint)

            Text(value)
                .font(.title3.bold())
                .contentTransition(.numericText())

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
        .accessibilityElement(
            children: .combine
        )
    }
}

private enum EventDashboardFolderError:
    LocalizedError
{
    case toEditIsNotFolder

    var errorDescription: String? {
        switch self {
        case .toEditIsNotFolder:
            return "The To Edit item is not a folder."
        }
    }
}

private enum EventDashboardFolderService {
    static func countToEditPhotos(
        reference: EventFolderReference,
        photos: [ServerPhotoRecord]
    ) throws -> Int {
        let resolved =
        try FolderBookmarkService.resolve(
            reference.bookmarkData
        )

        let eventFolderURL = resolved.url
        let accessed =
        eventFolderURL
            .startAccessingSecurityScopedResource()

        guard accessed else {
            throw ToEditSyncError
                .sourceFolderUnavailable
        }

        defer {
            eventFolderURL
                .stopAccessingSecurityScopedResource()
        }

        var eventFolderIsDirectory:
        ObjCBool = false

        guard
            FileManager.default.fileExists(
                atPath: eventFolderURL.path,
                isDirectory:
                    &eventFolderIsDirectory
            ),
            eventFolderIsDirectory.boolValue
        else {
            throw ToEditSyncError
                .sourceFolderUnavailable
        }

        let toEditURL =
        eventFolderURL.appendingPathComponent(
            UploadPreparationService
                .toEditFolderName,
            isDirectory: true
        )

        var toEditIsDirectory:
        ObjCBool = false

        guard FileManager.default.fileExists(
            atPath: toEditURL.path,
            isDirectory: &toEditIsDirectory
        ) else {
            return 0
        }

        guard toEditIsDirectory.boolValue else {
            throw EventDashboardFolderError
                .toEditIsNotFolder
        }

        let fileURLs =
        try FileManager.default
            .contentsOfDirectory(
                at: toEditURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey
                ],
                options: [.skipsHiddenFiles]
            )

        let matchingServerFilenames =
        Set(
            photos.map { photo in
                photo.originalFilename
                    .lowercased()
            }
        )

        return try fileURLs.reduce(0) {
            count,
            fileURL in

            let values =
            try fileURL.resourceValues(
                forKeys: [
                    .isRegularFileKey
                ]
            )

            guard
                values.isRegularFile == true,
                matchingServerFilenames.contains(
                    fileURL.lastPathComponent
                        .lowercased()
                )
            else {
                return count
            }

            return count + 1
        }
    }
}
