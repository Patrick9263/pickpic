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
                            isDraggable: true
                        )
                        .onDrag {
                            dragProvider(for: photo)
                        }
                    } else {
                        LikedPhotoRow(
                            photo: photo,
                            isDraggable: false
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

private struct LikedPhotoRow: View {
    let photo: ServerPhotoRecord

    /*
     * False until an event folder is selected, because without one
     * there is no To Edit folder to drag the RAW out of.
     */
    let isDraggable: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .foregroundStyle(.red)

            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                Text(photo.originalFilename)
                    .lineLimit(1)

                Label(
                    photo.workflowStatus.title,
                    systemImage:
                        photo.workflowStatus
                        .systemImage
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(photo.heartCount)")
                .font(.headline)

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
