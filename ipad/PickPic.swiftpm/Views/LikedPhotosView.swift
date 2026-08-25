import Combine
import SwiftUI
import UniformTypeIdentifiers

struct LikedPhotosView: View {
    let event: PickPicEvent
    
    @EnvironmentObject private var configuration:
    APIConfigurationStore
    
    @EnvironmentObject private var eventFolders:
    EventFolderStore

    @EnvironmentObject private var feedback:
    AppFeedbackStore
    
    @EnvironmentObject private var finishedEdits:
    FinishedEditsWatcher

    @StateObject private var viewModel =
    LikedPhotosViewModel()
    
    @State private var showingFolderPicker = false

    @State private var dragErrorMessage: String?


    private var folderReference:
    EventFolderReference?
    {
        eventFolders.reference(
            for: event.id
        )
    }
    
    var body: some View {
        List {
            eventFolderSection

            if folderReference != nil {
                automaticSyncSection
            }

            likedPhotosSection
            
            if let syncResult =
                viewModel.syncResult {
                syncResultSection(
                    syncResult
                )
            }
            
            if let errorMessage =
                viewModel.errorMessage {
                Section {
                    Label(
                        errorMessage,
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                }
            }
            
            if let loadErrorMessage =
                eventFolders.loadErrorMessage {
                Section {
                    Label(
                        loadErrorMessage,
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                }
            }

            if let dragErrorMessage {
                Section {
                    Label(
                        dragErrorMessage,
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Liked Photos")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshAndSync()
        }
        .toolbar {
            ToolbarItem(
                placement: .topBarTrailing
            ) {
                Button {
                    Task {
                        await refreshAndSync()
                    }
                } label: {
                    Label(
                        "Refresh",
                        systemImage:
                            "arrow.clockwise"
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if
                let folderReference,
                !viewModel.likedPhotos.isEmpty
            {
                Button {
                    Task {
                        await syncRequestedPhotos(
                            reference:
                                folderReference
                        )
                    }
                } label: {
                    if viewModel.isSyncing {
                        HStack(spacing: 10) {
                            ProgressView()
                            
                            Text("Syncing requested photos…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            "Sync Now",
                            systemImage:
                                "folder.badge.plus"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isSyncing)
                .padding()
                .background(.regularMaterial)
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case let .success(folderURL):
                do {
                    try eventFolders.saveFolder(
                        folderURL,
                        for: event
                    )

                    Task {
                        await refreshAndSync()
                    }
                } catch {
                    viewModel.showError(error)
                }
                
            case let .failure(error):
                viewModel.showError(error)
            }
        }
        .task(id: event.id) {
            await refreshAndSync()
        }
        .onChange(
            of: folderReference?.updatedAt,
            initial: true
        ) { _, _ in
            startWatchingFinishedEdits()
        }
        /*
         * The watch outlives this screen, so a final uploaded from
         * elsewhere has to be reflected here when the list is visible.
         */
        .onChange(
            of: finishedEdits.uploadGeneration
        ) { _, _ in
            Task {
                await viewModel.load(
                    eventID: event.id,
                    using: configuration
                )
            }
        }
    }
    
    private var eventFolderSection: some View {
        Section("Event Folder") {
            if let folderReference {
                LabeledContent(
                    "Folder",
                    value:
                        folderReference.folderName
                )
                
                if FolderBookmarkService
                    .canAccessFolder(
                        using:
                            folderReference
                            .bookmarkData
                    )
                {
                    Label(
                        "Folder available",
                        systemImage:
                            "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        """
                        Folder needs to be selected again
                        """,
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                
                Button("Change Event Folder") {
                    showingFolderPicker = true
                }
            } else {
                Text(
                    """
                    Select the folder containing this \
                    event's original RAW files.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                
                Button {
                    showingFolderPicker = true
                } label: {
                    Label(
                        "Select Event Folder",
                        systemImage: "folder"
                    )
                }
            }
        }
    }
    
    private var automaticSyncSection: some View {
        Section("Automatic Sync") {
            Label(
                """
                PickPic checks saved event folders for newly liked \
                photos about every 30 seconds while the app is open.
                """,
                systemImage:
                    "arrow.triangle.2.circlepath"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Label(
                """
                It also watches Edited for this event and uploads \
                finished edits as they appear, including after you leave \
                this screen. Keeping PickPic on screen beside your editor \
                keeps the check running while you work. It pauses only \
                when PickPic is fully in the background — your editor \
                taken full screen, the iPad locked, or PickPic swiped \
                away — and resumes as soon as you return.
                """,
                systemImage: "checkmark.seal"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if finishedEdits.uploads.isUploading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text(
                        finishedEdits.uploads.currentFilename
                        ?? "Uploading finished edits…"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            if let lastCheckedAt =
                viewModel.lastCheckedAt {
                LabeledContent(
                    "Last checked",
                    value:
                        lastCheckedAt.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                )
            }

            Text(
                """
                Requested RAW files are copied into To Edit. \
                Originals are never moved or deleted.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var likedPhotosSection: some View {
        Section {
            if
                viewModel.isLoading,
                viewModel.photos.isEmpty
            {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if viewModel.likedPhotos.isEmpty {
                Text(
                    """
                    No photos currently have any likes.
                    """
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(
                    viewModel.likedPhotos
                ) { photo in
                    /*
                     * Only a row backed by an event folder is
                     * draggable. Attaching the gesture regardless lets
                     * the row lift while carrying an empty provider,
                     * which reads as the drop target silently refusing
                     * a perfectly good file.
                     */
                    if folderReference != nil {
                        LikedPhotoRow(
                            photo: photo,
                            isDraggable: true,
                            onCopyName: {
                                copyBaseName(for: photo)
                            }
                        )
                        .onDrag {
                            dragProvider(for: photo)
                        }
                    } else {
                        LikedPhotoRow(
                            photo: photo,
                            isDraggable: false,
                            onCopyName: {
                                copyBaseName(for: photo)
                            }
                        )
                    }
                }
            }
        } header: {
            Text(
                "Liked Photos (\(viewModel.likedPhotos.count))"
            )
        } footer: {
            if !viewModel.likedPhotos.isEmpty {
                if folderReference == nil {
                    Text(
                        """
                        Select this event's folder above to drag \
                        these photos into an editor.
                        """
                    )
                } else {
                    Text(
                        """
                        Open an editor beside PickPic, then drag \
                        a photo into it. Save the result into \
                        the event's Edited folder and PickPic \
                        uploads it as the final.
                        """
                    )
                }
            }
        }
    }

    private func syncResultSection(
        _ result: ToEditSyncResult
    ) -> some View {
        Section("Last Sync") {
            LabeledContent(
                "Liked photos",
                value: "\(result.likedPhotoCount)"
            )
            
            LabeledContent(
                "Copied",
                value: "\(result.copiedPhotoCount)"
            )
            
            LabeledContent(
                "Already in To Edit",
                value: "\(result.alreadyPresentCount)"
            )
            
            LabeledContent(
                "Newly Marked Editing",
                value: "\(viewModel.markedEditingCount)"
            )
            
            LabeledContent(
                "Currently Editing",
                value: "\(viewModel.editingLikedPhotoCount)"
            )
            
            if !result.missingFilenames.isEmpty {
                VStack(
                    alignment: .leading,
                    spacing: 6
                ) {
                    Label(
                    """
                    Missing source files \
                    (\(result.missingFilenames.count))
                    """,
                    systemImage:
                        "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    
                    ForEach(
                        result.missingFilenames,
                        id: \.self
                    ) { filename in
                        Text(filename)
                            .font(.caption)
                    }
                }
            }
            
            if !viewModel.workflowUpdateFailures.isEmpty {
                VStack(
                    alignment: .leading,
                    spacing: 6
                ) {
                    Label(
                    """
                    Unable to mark Editing \
                    (\(viewModel.workflowUpdateFailures.count))
                    """,
                    systemImage:
                        "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    
                    ForEach(
                        viewModel.workflowUpdateFailures,
                        id: \.self
                    ) { filename in
                        Text(filename)
                            .font(.caption)
                    }
                }
            }
            
            Text(
                result.syncedAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func syncRequestedPhotos(
        reference: EventFolderReference
    ) async {
        let previousSyncDate =
        viewModel.syncResult?.syncedAt

        await viewModel.sync(
            eventID: event.id,
            reference: reference,
            using: configuration
        )

        guard
            let result = viewModel.syncResult,
            result.syncedAt != previousSyncDate,
            result.copiedPhotoCount > 0
        else {
            return
        }

        let fileDescription =
        result.copiedPhotoCount == 1
        ? "RAW file"
        : "RAW files"

        feedback.show(
            title: "Liked photos synced",
            detail:
                "\(event.title): copied \(result.copiedPhotoCount) \(fileDescription) into To Edit.",
            systemImage: "heart.circle.fill"
        )
    }

    /*
     * Puts the filename without its extension on the clipboard, because
     * an editor exporting the edit does not prefill a name and the
     * Edited folder is matched on exactly this stem.
     *
     * Original casing is kept for legibility; the match lowercases both
     * sides, so it does not have to be typed back exactly.
     */
    private func copyBaseName(
        for photo: ServerPhotoRecord
    ) {
        let baseName =
        (photo.originalFilename as NSString)
            .deletingPathExtension

        UIPasteboard.general.string = baseName

        feedback.show(
            title: "Name copied",
            detail:
                "Paste \(baseName) when saving the edit into the Edited folder.",
            systemImage: "doc.on.doc.fill"
        )
    }

    /*
     * Supplies the RAW to a drop target such as an editor running in
     * Split View.
     *
     * Staging happens here, synchronously, rather than inside an
     * asynchronous file-representation handler. That handler runs after
     * the drop, so anything it throws surfaces nowhere and the drop just
     * silently does nothing. Doing the copy up front costs a moment when
     * the drag starts but makes failures visible.
     *
     * NSItemProvider(contentsOf:) registers the file the same way the
     * Files app does, deriving the type from the URL, instead of
     * hand-rolling a representation a drop target might not accept.
     */
    /*
     * Most specific first: a target picking the first type it
     * understands should get the truest description of the file.
     * The generic image types are the fallback that lets an editor
     * accept a RAW this system has no declaration for.
     */
    static func dragTypeIdentifiers(
        for filename: String
    ) -> [String] {
        var identifiers: [String] = []

        let fileExtension =
        (filename as NSString).pathExtension

        if
            let resolved = UTType(
                filenameExtension: fileExtension
            )?.identifier
        {
            identifiers.append(resolved)
        }

        identifiers.append(UTType.rawImage.identifier)
        identifiers.append(UTType.image.identifier)

        var seen: Set<String> = []

        return identifiers.filter { identifier in
            seen.insert(identifier).inserted
        }
    }

    private func dragProvider(
        for photo: ServerPhotoRecord
    ) -> NSItemProvider {
        guard let folderReference else {
            return NSItemProvider()
        }

        do {
            let stagedURL =
            try ToEditSyncService
                .stageFileForEditing(
                    named: photo.originalFilename,
                    reference: folderReference
                )

            let provider = NSItemProvider()

            provider.suggestedName =
            photo.originalFilename

            /*
             * A drop target decides whether to accept a drag from the
             * types the session advertises, before asking for any data.
             * Relying on the extension alone means advertising nothing
             * useful on a system that does not declare Sony RAW, and the
             * target then refuses the drop with no badge and no error.
             */
            for identifier in Self.dragTypeIdentifiers(
                for: photo.originalFilename
            ) {
                provider.registerFileRepresentation(
                    forTypeIdentifier: identifier,
                    fileOptions: [],
                    visibility: .all
                ) { completion in
                    /*
                     * Already staged above, so this only hands back a
                     * path and cannot fail silently.
                     */
                    completion(stagedURL, false, nil)

                    return nil
                }
            }

            dragErrorMessage = nil

            return provider
        } catch {
            dragErrorMessage =
            error.localizedDescription

            return NSItemProvider()
        }
    }

    /*
     * Opening this screen is what marks an event as the one being worked
     * on, so it is also what hands the watch to the app-level watcher.
     * Losing the folder stops it rather than leaving it scanning a
     * reference it can no longer resolve.
     */
    private func startWatchingFinishedEdits() {
        guard let folderReference else {
            finishedEdits.stop()

            return
        }

        finishedEdits.watch(
            eventID: event.id,
            reference: folderReference,
            configuration: configuration,
            feedback: feedback
        )
    }

    private func refreshAndSync() async {
        if let folderReference {
            await syncRequestedPhotos(
                reference: folderReference
            )
        } else {
            await viewModel.load(
                eventID: event.id,
                using: configuration
            )
        }
    }
}

/*
 * Watches one event's Edited folder and uploads finished edits as they
 * appear. Owned by the app rather than by the liked-photos screen, so
 * moving to another screen mid-session no longer stops the watch — the
 * common case being a swap out to Affinity and back.
 *
 * It deliberately follows a single event, the one whose liked photos
 * were last opened, rather than every event PickPic knows about. The
 * folders belong to shoots that may be long finished, and scanning them
 * all would do a lot of security-scoped work nobody asked for.
 *
 * iPadOS suspends the app in the background and offers no way to watch a
 * user folder while suspended, so the periodic loop cannot see an export
 * made while Affinity is frontmost. scanNow covers that: the app scans
 * the moment it becomes active instead of waiting out the remainder of
 * the interval. Once a final is found the upload itself survives
 * backgrounding through BackgroundUploadSession.
 *
 * Lives here rather than in its own file to avoid editing
 * project.pbxproj, matching ThumbnailCache below. Worth extracting when
 * the project file is being changed anyway.
 */
@MainActor
final class FinishedEditsWatcher: ObservableObject {
    /*
     * Incremented after each upload so a visible liked-photos list can
     * refresh. The watcher cannot reach that view's own view model, and
     * the photos just delivered would otherwise keep reading as still
     * waiting for an edit.
     */
    @Published private(set) var uploadGeneration = 0

    /*
     * Exposed so the liked-photos screen can keep showing per-file
     * progress. A nested ObservableObject does not republish on its own,
     * hence the forwarding in init.
     */
    let uploads = FinalUploadsViewModel()

    private var forwarding: AnyCancellable?

    private var suspensions = 0

    private var watchedEventID: String?
    private var reference: EventFolderReference?
    private var configuration: APIConfigurationStore?
    private var feedback: AppFeedbackStore?
    private var loop: Task<Void, Never>?

    private static let interval = Duration.seconds(30)

    init() {
        forwarding = uploads.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    func watch(
        eventID: String,
        reference: EventFolderReference,
        configuration: APIConfigurationStore,
        feedback: AppFeedbackStore
    ) {
        self.configuration = configuration
        self.feedback = feedback
        self.reference = reference

        /*
         * Restarting the loop on every appearance would reset the
         * interval and rescan immediately, so an unchanged watch is left
         * running as it is.
         */
        if
            watchedEventID == eventID,
            loop?.isCancelled == false
        {
            return
        }

        watchedEventID = eventID

        loop?.cancel()

        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanOnce()

                try? await Task.sleep(
                    for: Self.interval
                )
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        watchedEventID = nil
        reference = nil
    }

    /*
     * The Upload Finals screen drives the same folder through its own
     * view model, whose busy check cannot see this one. Rather than have
     * both upload the same file, the explicit screen takes precedence
     * and the watch stands down while it is open. Counted rather than a
     * flag so overlapping presentations cannot resume it early.
     */
    func suspend() {
        suspensions += 1
    }

    func resume() {
        suspensions = max(suspensions - 1, 0)
    }

    /*
     * Called when the app becomes active. The periodic loop makes no
     * progress while suspended, so without this a finished edit waits out
     * whatever remained of the interval before anything notices it.
     */
    func scanNow() {
        guard watchedEventID != nil else {
            return
        }

        Task {
            await scanOnce()
        }
    }

    private func scanOnce() async {
        guard suspensions == 0 else {
            return
        }

        guard
            let eventID = watchedEventID,
            let reference,
            let configuration
        else {
            return
        }

        await uploads.load(
            eventID: eventID,
            reference: reference,
            using: configuration
        )

        let readyCount = uploads.scanResult?
            .candidates.count
        ?? 0

        guard readyCount > 0 else {
            return
        }

        await uploads.uploadAll(
            eventID: eventID,
            reference: reference,
            using: configuration
        )

        guard
            let uploadedCount =
                uploads.lastUploadedCount,
            uploadedCount > 0
        else {
            return
        }

        feedback?.show(
            title: "Finals uploaded",
            detail:
                uploadedCount == 1
            ? "1 edited photo was uploaded from Edited."
            : "\(uploadedCount) edited photos were uploaded from Edited.",
            systemImage: "checkmark.seal.fill"
        )

        uploadGeneration += 1
    }
}

/*
 * Stored thumbnails, kept in memory so scrolling a list does not refetch
 * images that have already been decoded. Bounded by count rather than
 * bytes because these are small, fixed-size proofs.
 */
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let storage = NSCache<
        NSString,
        UIImage
    >()

    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        storage.countLimit = 300
    }

    func cachedImage(
        forPath path: String
    ) -> UIImage? {
        storage.object(
            forKey: path as NSString
        )
    }

    func image(
        forPath path: String,
        using configuration: APIConfigurationStore
    ) async -> UIImage? {
        if let cached = cachedImage(forPath: path) {
            return cached
        }

        if let existing = inFlight[path] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            guard
                let client = try? configuration
                    .makeClient(),
                let data = try? await client
                    .fetchImageData(path: path),
                let image = UIImage(data: data)
            else {
                return nil
            }

            return image
        }

        inFlight[path] = task

        let image = await task.value

        inFlight[path] = nil

        if let image {
            storage.setObject(
                image,
                forKey: path as NSString
            )
        }

        return image
    }
}

private struct PhotoThumbnail: View {
    let path: String?
    let size: CGFloat

    @EnvironmentObject private var configuration:
    APIConfigurationStore

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(
                        contentMode: .fill
                    )
            } else {
                /*
                 * A photo with no stored thumbnail is not an error: it
                 * predates variant generation, or its upload has not
                 * finished. The placeholder says so quietly.
                 */
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(
                            systemName: "photo"
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(
            width: size,
            height: size
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 6
            )
        )
        .task(id: path) {
            guard
                let path,
                image == nil
            else {
                return
            }

            image = await ThumbnailCache.shared
                .image(
                    forPath: path,
                    using: configuration
                )
        }
    }
}

private struct LikedPhotoRow: View {
    let photo: ServerPhotoRecord

    /*
     * False until an event folder is selected, because without one
     * there is no To Edit folder to drag the RAW out of.
     */
    let isDraggable: Bool

    let onCopyName: () -> Void

    private var subtitle: String {
        [
            photo.capturedAtDisplay,
            photo.workflowStatus.title
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnail(
                path: photo.thumbnailPath,
                size: 52
            )

            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                Text(photo.originalFilename)
                    .lineLimit(1)

                /*
                 * Capture time distinguishes frames that a repeated
                 * status label cannot, and Sony reuses filenames across
                 * shoots, so it is often the only thing that does.
                 */
                Label(
                    subtitle,
                    systemImage:
                        photo.workflowStatus
                        .systemImage
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Label(
                "\(photo.heartCount)",
                systemImage: "heart.fill"
            )
            .font(.subheadline)
            .foregroundStyle(.red)
            .labelStyle(.titleAndIcon)

            Button(action: onCopyName) {
                Label(
                    "Copy Name",
                    systemImage: "doc.on.doc"
                )
                .labelStyle(.iconOnly)
            }
            /*
             * Borderless so the button takes the tap without the row's
             * drag gesture swallowing it.
             */
            .buttonStyle(.borderless)
            .accessibilityLabel(
                "Copy the name of \(photo.originalFilename) without its extension"
            )

            if isDraggable {
                Image(
                    systemName:
                        "line.3.horizontal"
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(
                    "Drag \(photo.originalFilename) into an editor"
                )
            }
        }
        .padding(.vertical, 3)
    }
}
