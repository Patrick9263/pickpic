import SwiftUI
import UniformTypeIdentifiers

struct PhotoImportView: View {
    let event: PickPicEvent
    
    @EnvironmentObject private var uploadQueue:
    UploadQueueStore
    @EnvironmentObject private var eventFolders:
    EventFolderStore
    
    @StateObject private var viewModel =
    PhotoImportViewModel()
    
    @State private var showingFolderPicker = false
    @State private var hasQueuedSelection = false
    @State private var showingQueue = false
    
    @State private var showingQueueError = false
    @State private var queueErrorMessage = ""
    
    var body: some View {
        List {
            if let folderName = viewModel.folderName {
                Section("Selection") {
                    LabeledContent(
                        "Event",
                        value: event.title
                    )
                    
                    LabeledContent(
                        "Folder",
                        value: folderName
                    )
                    
                    LabeledContent(
                        "Photos",
                        value:
                            "\(viewModel.photos.count)"
                    )
                    
                    LabeledContent(
                        "Source size",
                        value: formattedByteCount(
                            viewModel.totalBytes
                        )
                    )
                }
                
                if !viewModel.photos.isEmpty {
                    Section(
                        "Files (\(viewModel.photos.count))"
                    ) {
                        ForEach(
                            viewModel.photos
                        ) { photo in
                            SourcePhotoRow(
                                photo: photo
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Import Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(
                placement: .topBarTrailing
            ) {
                Button {
                    viewModel.clearError()
                    showingFolderPicker = true
                } label: {
                    Label(
                        "Choose Folder",
                        systemImage: "folder"
                    )
                }
            }
        }
        .overlay {
            importState
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.photos.isEmpty {
                queueControls
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case let .success(folderURL):
                hasQueuedSelection = false
                
                Task {
                    await viewModel.scan(
                        folderURL: folderURL
                    )
                }
                
            case let .failure(error):
                viewModel.showError(error)
            }
        }
        .navigationDestination(
            isPresented: $showingQueue
        ) {
            UploadQueueView(event: event)
        }
        .alert(
            "Unable to Add Upload",
            isPresented: $showingQueueError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(queueErrorMessage)
        }
    }
    
    private var queueControls: some View {
        VStack(spacing: 8) {
            Button {
                queueSelection()
            } label: {
                Label(
                    hasQueuedSelection
                    ? "View Upload Queue"
                    : "Add to Upload Queue",
                    systemImage:
                        hasQueuedSelection
                    ? "arrow.up.circle.fill"
                    : "plus.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Text(
                """
                This only saves the upload job. \
                No source files are changed yet.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial)
    }
    
    @ViewBuilder
    private var importState: some View {
        if viewModel.isScanning {
            ProgressView("Scanning folder…")
        } else if let errorMessage =
                    viewModel.errorMessage {
            ContentUnavailableView {
                Label(
                    "Unable to Read Folder",
                    systemImage:
                        "exclamationmark.triangle"
                )
            } description: {
                Text(errorMessage)
            } actions: {
                Button(
                    "Choose Another Folder"
                ) {
                    viewModel.clearError()
                    showingFolderPicker = true
                }
            }
        } else if viewModel.folderName == nil {
            ContentUnavailableView {
                Label(
                    "Choose an Event Folder",
                    systemImage: "folder"
                )
            } description: {
                Text(
                    """
                    Select the folder containing the RAW \
                    photos for \(event.title).
                    """
                )
            } actions: {
                Button("Choose Folder") {
                    showingFolderPicker = true
                }
            }
        } else if viewModel.photos.isEmpty {
            ContentUnavailableView {
                Label(
                    "No Supported Photos",
                    systemImage:
                        "photo.on.rectangle.angled"
                )
            } description: {
                Text(
                    """
                    This folder does not contain any \
                    recognized RAW or JPEG photos.
                    """
                )
            } actions: {
                Button(
                    "Choose Another Folder"
                ) {
                    showingFolderPicker = true
                }
            }
        }
    }
    
    private func queueSelection() {
        if hasQueuedSelection {
            showingQueue = true
            return
        }
        
        do {
            let job =
            try viewModel.makeUploadJob(
                for: event
            )
            try eventFolders.save(job: job)
            try uploadQueue.add(job)
            hasQueuedSelection = true
        } catch {
            queueErrorMessage =
            error.localizedDescription
            showingQueueError = true
        }
    }
    
    private func formattedByteCount(
        _ byteCount: Int64
    ) -> String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }
}

private struct SourcePhotoRow: View {
    let photo: SourcePhoto
    
    var body: some View {
        HStack(spacing: 12) {
            Image(
                systemName:
                    photo.kind.systemImage
            )
            .frame(width: 28)
            .foregroundStyle(.tint)
            
            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                Text(photo.filename)
                    .lineLimit(1)
                
                Text(photo.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Text(
                ByteCountFormatter.string(
                    fromByteCount:
                        photo.byteSize,
                    countStyle: .file
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
