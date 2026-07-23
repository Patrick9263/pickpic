import SwiftUI
import UniformTypeIdentifiers

struct LikedPhotosView: View {
    let event: PickPicEvent
    
    @EnvironmentObject private var configuration:
    APIConfigurationStore
    
    @EnvironmentObject private var eventFolders:
    EventFolderStore
    
    @StateObject private var viewModel =
    LikedPhotosViewModel()
    
    @State private var showingFolderPicker = false
    
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
        }
        .navigationTitle("Liked Photos")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.load(
                eventID: event.id,
                using: configuration
            )
        }
        .toolbar {
            ToolbarItem(
                placement: .topBarTrailing
            ) {
                Button {
                    Task {
                        await viewModel.load(
                            eventID: event.id,
                            using: configuration
                        )
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
                        await viewModel.sync(
                            eventID: event.id,
                            reference:
                                folderReference,
                            using: configuration
                        )
                    }
                } label: {
                    if viewModel.isSyncing {
                        HStack(spacing: 10) {
                            ProgressView()
                            
                            Text("Syncing to To Edit…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            "Sync Liked Photos to To Edit",
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
                } catch {
                    viewModel.showError(error)
                }
                
            case let .failure(error):
                viewModel.showError(error)
            }
        }
        .task(id: event.id) {
            await viewModel.load(
                eventID: event.id,
                using: configuration
            )
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
    
    private var likedPhotosSection: some View {
        Section(
            "Liked Photos (\(viewModel.likedPhotos.count))"
        ) {
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
                    LikedPhotoRow(photo: photo)
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
                value:
                    "\(result.likedPhotoCount)"
            )
            
            LabeledContent(
                "Copied",
                value:
                    "\(result.copiedPhotoCount)"
            )
            
            LabeledContent(
                "Already in To Edit",
                value:
                    "\(result.alreadyPresentCount)"
            )
            
            if result.skippedFinalCount > 0 {
                LabeledContent(
                    "Already final",
                    value:
                        "\(result.skippedFinalCount)"
                )
            }
            
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
}

private struct LikedPhotoRow: View {
    let photo: ServerPhotoRecord
    
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
        }
        .padding(.vertical, 3)
    }
}
