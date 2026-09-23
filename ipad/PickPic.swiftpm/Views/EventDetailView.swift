import SwiftUI
import UniformTypeIdentifiers

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

    /*
     * Mirrors uploadQueue.jobs, filtered to this event. Reading
     * uploadQueue.jobs(for:) directly from the environment object here
     * has the same failure mode #315 found in EventListView's sidebar:
     * NavigationSplitView does not reliably re-run this view's body from
     * the @EnvironmentObject publish alone while its column sits
     * unfocused, so a stage transition landing then could leave the
     * primary-action card and progress state stale until some unrelated
     * navigation forced a redraw. The explicit onReceive subscription
     * below still delivers while unfocused, and writing into this @State
     * is what reliably forces SwiftUI to redraw the views that read it.
     */
    @State private var eventJobsState:
    [UploadJob] = []

    @State private var showingRenameEvent = false
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false

    /*
     * Importing runs from this screen rather than from a pushed one:
     * pick a folder, confirm the scan, and the upload starts. The follow
     * up is deferred to the sheet's dismissal instead of being triggered
     * beside it, because a push or a second picker raised while the sheet
     * is still animating away is dropped.
     */
    @StateObject private var importModel =
    PhotoImportViewModel()

    @State private var showingImportFolderPicker = false
    @State private var showingImportConfirmation = false
    @State private var showingUploadQueue = false
    @State private var importQueueErrorMessage: String?
    @State private var importScanTask: Task<Void, Never>?

    @State private var importDismissAction:
    ImportDismissAction?
    
    @State private var showingDeleteError = false
    @State private var deleteErrorMessage = ""

    @State private var showingStopOfferingRawsConfirmation = false
    @State private var isStoppingOfferingRaws = false
    @State private var showingStopOfferingRawsError = false
    @State private var stopOfferingRawsErrorMessage = ""

    @State private var isUpdatingRawRequestsEnabled = false
    @State private var showingRawRequestsEnabledError = false
    @State private var rawRequestsEnabledErrorMessage = ""
    
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
    
    private enum ImportDismissAction {
        case chooseAnotherFolder
        case openUploadQueue
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
        eventJobsState
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
        event.status
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
                switch primaryAction {
                case .importPhotos:
                    Button {
                        beginImport()
                    } label: {
                        primaryActionLabel(
                            for: primaryAction
                        )
                    }
                    // Borderless so the button takes the tap without the row's
                    // gesture recognizer swallowing the first one (see #122).
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    .listRowBackground(
                        Color.accentColor
                    )
                    .foregroundStyle(.white)

                case .continueUpload,
                        .uploadReadyFinals,
                        .reviewLiked,
                        .publish:
                    NavigationLink {
                        primaryDestination(
                            for: primaryAction
                        )
                    } label: {
                        primaryActionLabel(
                            for: primaryAction
                        )
                    }
                    .listRowBackground(
                        Color.accentColor
                    )
                    .foregroundStyle(.white)
                }
            } footer: {
                Text(primaryAction.reason)
            }
        }
    }

    private func primaryActionLabel(
        for action: PrimaryAction
    ) -> some View {
        Label(
            action.title,
            systemImage: action.systemImage
        )
        .font(.headline)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    @ViewBuilder
    private func primaryDestination(
        for action: PrimaryAction
    ) -> some View {
        switch action {
        case .importPhotos:
            /*
             * Import opens the folder picker from this screen instead of
             * pushing anything, so this case is never reached.
             */
            EmptyView()

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

    /*
     * body is split into staged `let` bindings below, each its own
     * statement rather than one continuous modifier chain: CI's swiftc
     * (slower than this machine's, so the timeout is hit there and not
     * always reproducible locally) kept timing out type-checking this
     * expression as more `.alert`s were added for the RAW-requests
     * feature, each time blaming an arbitrary unrelated line since the
     * timeout is a whole-chain budget. A modifier chain is itself one
     * expression the type checker solves as a unit; splitting it into
     * named stages gives it several much smaller ones instead.
     */
    var body: some View {
        let eventList = eventListContent
            .refreshable {
                await loadDashboard()
            }
            .onAppear {
                Task {
                    await loadDashboard()
                }
            }
            .onReceive(uploadQueue.$jobs) { jobs in
                eventJobsState = jobs.filter { job in
                    job.eventID == event.id
                }
            }
            /*
             * The photo/liked/final counts in dashboardStatistics (and the
             * copy of them the sidebar shows) come from the server, not from
             * uploadQueue -- fetched only by loadDashboard(), which otherwise
             * only runs on .onAppear and pull-to-refresh. Nothing was
             * re-fetching it as proofs actually landed, so those counts sat
             * frozen at whatever they were when the screen was last opened
             * until the user navigated away and back (#315). Poll while this
             * event has unfinished jobs so they move on their own during a
             * run; restarting the task on the boolean's id means it stops
             * cleanly the moment there is nothing left to upload. The fetch
             * happens *before* each sleep (not after) because a small batch
             * can finish uploading in well under the interval -- sleeping
             * first would let the task get cancelled on completion without
             * ever having fetched once.
             */
            .task(id: unfinishedEventJobCount > 0) {
                guard unfinishedEventJobCount > 0 else {
                    return
                }

                while !Task.isCancelled {
                    await loadDashboard()

                    try? await Task.sleep(
                        for: .seconds(5)
                    )
                }
            }
            /*
             * Catches the same fast-batch case from the other side: if the
             * run finished between two polls above (or entirely within one
             * interval), this fires the moment unfinishedEventJobCount drops
             * to zero so completion is reflected immediately rather than on
             * whatever the next poll or screen visit would have been.
             */
            .onChange(of: unfinishedEventJobCount) { oldCount, newCount in
                guard oldCount > 0, newCount == 0 else {
                    return
                }

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
            .fileImporter(
                isPresented: $showingImportFolderPicker,
                allowedContentTypes: [.folder]
            ) { result in
                handleImportFolderSelection(result)
            }

        let presentedEventList = eventList
            .sheet(
                isPresented: $showingImportConfirmation,
                onDismiss: handleImportSheetDismiss
            ) {
                PhotoImportView(
                    event: event,
                    viewModel: importModel,
                    queueErrorMessage:
                        importQueueErrorMessage,
                    onChooseAnotherFolder: {
                        importDismissAction =
                            .chooseAnotherFolder
                        showingImportConfirmation = false
                    },
                    onStartUpload: startImportedUpload
                )
                .presentationDetents([.medium, .large])
            }
            .navigationDestination(
                isPresented: $showingUploadQueue
            ) {
                UploadQueueView(event: event)
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

        let coreAlertedEventList = presentedEventList
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

        return coreAlertedEventList
            .alert(
                "Stop Offering Originals for \(event.title)?",
                isPresented:
                    $showingStopOfferingRawsConfirmation
            ) {
                Button(
                    "Stop Offering Originals",
                    role: .destructive
                ) {
                    Task {
                        await stopOfferingRawRequests()
                    }
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    """
                    This cancels every pending RAW delivery for this event and \
                    frees the storage now, regardless of collection status. \
                    Requests stay off until you turn them back on.
                    """
                )
            }
            .alert(
                "Unable to Stop Offering Originals",
                isPresented: $showingStopOfferingRawsError
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(stopOfferingRawsErrorMessage)
            }
            .alert(
                "Unable to Update RAW Requests",
                isPresented: $showingRawRequestsEnabledError
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(rawRequestsEnabledErrorMessage)
            }
    }

    @ViewBuilder
    private var eventListContent: some View {
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

            photosSection

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
            
            rawRequestsSection

            manageEventSection
        }
    }

    private func beginImport() {
        importQueueErrorMessage = nil
        importModel.clearError()
        showingImportFolderPicker = true
    }

    private func handleImportFolderSelection(
        _ result: Result<URL, Error>
    ) {
        importQueueErrorMessage = nil

        switch result {
        case let .success(folderURL):
            /*
             * The sheet goes up before the scan finishes so a folder full
             * of RAWs reports that it is being read rather than leaving
             * the tap looking ignored.
             */
            showingImportConfirmation = true

            importScanTask?.cancel()

            importScanTask = Task {
                await importModel.scan(
                    folderURL: folderURL
                )
            }

        case let .failure(error):
            importModel.showError(error)
            showingImportConfirmation = true
        }
    }

    /*
     * Queueing and starting are one action. The job is still saved to the
     * durable queue first, so an upload interrupted here is resumable from
     * the queue exactly as before.
     */
    private func startImportedUpload() {
        do {
            let job =
            try importModel.makeUploadJob(
                for: event
            )

            try eventFolders.save(job: job)
            try uploadQueue.add(job)

            uploadQueue
                .startUserInitiatedUploadPipeline(
                    jobID: job.id,
                    using: configuration
                )

            importQueueErrorMessage = nil
            importDismissAction = .openUploadQueue
            showingImportConfirmation = false
        } catch {
            importQueueErrorMessage =
            error.localizedDescription
        }
    }

    private func handleImportSheetDismiss() {
        importScanTask?.cancel()
        importScanTask = nil
        importModel.reset()
        importQueueErrorMessage = nil

        let action = importDismissAction
        importDismissAction = nil

        switch action {
        case .chooseAnotherFolder:
            showingImportFolderPicker = true

        case .openUploadQueue:
            showingUploadQueue = true

        case nil:
            break
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

            /*
             * There is no single-event GET route, only the list one
             * fetchEvents() already calls elsewhere -- refetching it here
             * is what picks up fields set from outside this screen (the
             * RAW-requests toggle changed on the web dashboard, a rename,
             * a status change) since `event` is seeded once from the
             * value this view was pushed with and nothing otherwise
             * refreshes it while the screen stays open. Best-effort: a
             * failure here still lets the photo-derived statistics below
             * load normally.
             */
            do {
                let refreshedEvents =
                try await client.fetchEvents()

                if let refreshedEvent = refreshedEvents.first(
                    where: { $0.id == event.id }
                ) {
                    event = refreshedEvent
                    onEventUpdated(refreshedEvent)
                }
            } catch {
                print(
                    "Event refresh failed, dashboard statistics will still be attempted:",
                    error
                )
            }

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
        }
    }

    private func gallerySystemImage(
        for status: PickPicEvent.Status
    ) -> String {
        switch status {
        case .draft:
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

    /*
     * Pulled out of `body` as its own Section, not inlined: SwiftUI's
     * result-builder type checker times out on a List this long once
     * another multi-part Section is added inline (hit in CI, not locally,
     * since the compiler's timeout is load-dependent) -- splitting a
     * Section into its own `some View` property gives the type checker a
     * much smaller expression to solve per piece.
     */
    @ViewBuilder
    private var photosSection: some View {
        Section("Photos") {
            Button {
                beginImport()
            } label: {
                Label(
                    eventJobs.isEmpty
                    ? "Import Photos"
                    : "Add More Photos",
                    systemImage:
                        "photo.badge.plus"
                )
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
            }
            // Borderless so the button takes the tap without the row's
            // gesture recognizer swallowing the first one (see #122).
            .buttonStyle(.borderless)
            .contentShape(Rectangle())

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
    }

    @ViewBuilder
    private var manageEventSection: some View {
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

    @ViewBuilder
    private var rawRequestsSection: some View {
        Section {
            Toggle(
                "Allow Viewers to Request Originals",
                isOn: rawRequestsEnabledBinding
            )
            .disabled(isUpdatingRawRequestsEnabled)

            Button {
                showingStopOfferingRawsConfirmation = true
            } label: {
                Label(
                    "Stop Offering Originals",
                    systemImage: "stop.circle"
                )
            }
            .disabled(isStoppingOfferingRaws)
        } header: {
            Text("RAW Requests")
        } footer: {
            Text(
                """
                Turning requests off does not take back a RAW already \
                delivered to a viewer -- use Stop Offering Originals \
                below to also cancel every pending delivery and free \
                all storage for this event now, regardless of \
                collection status. Both are reversible: turn requests \
                back on and the next request re-uploads.
                """
            )
        }
    }

    /*
     * event.rawRequestsEnabled is optional (nil until the server has been
     * asked at least once, see PickPicEvent), so this reads nil as "on" --
     * the same default the model documents -- rather than exposing the
     * optionality to the Toggle, and writes go through
     * setRawRequestsEnabled(_:) so a failed request reverts the switch.
     */
    private var rawRequestsEnabledBinding: Binding<Bool> {
        Binding(
            get: { event.rawRequestsEnabled ?? true },
            set: { newValue in
                Task {
                    await setRawRequestsEnabled(newValue)
                }
            }
        )
    }

    private func setRawRequestsEnabled(
        _ enabled: Bool
    ) async {
        guard !isUpdatingRawRequestsEnabled else {
            return
        }

        isUpdatingRawRequestsEnabled = true

        defer {
            isUpdatingRawRequestsEnabled = false
        }

        do {
            let client =
            try configuration.makeClient()

            let updatedEvent =
            try await client.setRawRequestsEnabled(
                enabled,
                for: event.id
            )

            event = updatedEvent
            onEventUpdated(updatedEvent)
        } catch {
            rawRequestsEnabledErrorMessage =
            error.localizedDescription

            showingRawRequestsEnabledError = true
        }
    }

    private func stopOfferingRawRequests() async {
        guard !isStoppingOfferingRaws else {
            return
        }

        isStoppingOfferingRaws = true

        defer {
            isStoppingOfferingRaws = false
        }

        do {
            let client =
            try configuration.makeClient()

            let updatedEvent =
            try await client.stopOfferingRawRequests(
                eventID: event.id
            )

            event = updatedEvent
            onEventUpdated(updatedEvent)

            await loadDashboard()
        } catch {
            stopOfferingRawsErrorMessage =
            error.localizedDescription

            showingStopOfferingRawsError = true
        }
    }
}

private struct EventDetailDashboard: View {
    let statistics: EventPhotoStatistics?
    let readyFinalCount: Int?
    let toEditFileCount: Int?
    let incompleteUploadCount: Int
    let isLoading: Bool

    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass

    /*
     * The column count is chosen from the size class rather than
     * with `.adaptive`, because an adaptive grid inside a `List`
     * row reflows its column count as the pane width changes,
     * which changes the row height, which makes the list
     * re-measure the row. Dragging a Split View divider feeds that
     * cycle continuously and UIKit eventually kills the app with a
     * recursive layout loop. A size class only flips at discrete
     * breakpoints, so the row height cannot chase its own width.
     */
    private var columns: [GridItem] {
        let columnCount =
            horizontalSizeClass == .compact ? 2 : 4

        return Array(
            repeating: GridItem(
                .flexible(),
                spacing: 12
            ),
            count: columnCount
        )
    }

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
