import SwiftUI

/*
 * The confirmation step of the import flow, presented as a sheet from
 * EventDetailView once a folder has been picked. It owns no state: the
 * scan lives in the hub's view model so that picking a folder, starting
 * the pipeline and pushing the queue all happen in one place.
 *
 * The only decision here is "is this the right folder", which is why the
 * summary and the file list are the whole screen and Start Upload is the
 * single action.
 */
struct PhotoImportView: View {
    let event: PickPicEvent
    
    @ObservedObject var viewModel:
    PhotoImportViewModel
    
    let queueErrorMessage: String?
    let onChooseAnotherFolder: () -> Void
    let onStartUpload: () -> Void
    
    /*
     * Read only for the size estimate, which is averaged over what past
     * jobs actually converted. The sheet still drives nothing here.
     */
    @EnvironmentObject private var uploadQueue:
    UploadQueueStore
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                /*
                 * The problem states are drawn as an overlay, so the
                 * summary is only listed when there is something to
                 * confirm — otherwise it shows through them.
                 */
                if let folderName = viewModel.folderName,
                    !viewModel.photos.isEmpty {
                    Section {
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
                        
                        if let estimate =
                            proofSizeEstimate {
                            LabeledContent(
                                "Upload size",
                                value: "About "
                                    + formattedByteCount(
                                        estimate.byteCount
                                    )
                            )
                        }
                    } header: {
                        Text("Selection")
                    } footer: {
                        Text(uploadSizeFootnote)
                    }
                    
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
            .navigationTitle("Import Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(
                    placement: .topBarLeading
                ) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }
                
                ToolbarItem(
                    placement: .topBarTrailing
                ) {
                    Button {
                        onChooseAnotherFolder()
                    } label: {
                        Label(
                            "Choose Another Folder",
                            systemImage: "folder"
                        )
                    }
                    .disabled(viewModel.isScanning)
                }
            }
            .overlay {
                importState
            }
            .safeAreaInset(edge: .bottom) {
                if !viewModel.photos.isEmpty {
                    startControls
                }
            }
        }
    }
    
    private var startControls: some View {
        VStack(spacing: 8) {
            if let queueErrorMessage {
                Label(
                    queueErrorMessage,
                    systemImage:
                        "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
            }
            
            Button {
                onStartUpload()
            } label: {
                Label(
                    "Start Upload",
                    systemImage:
                        "arrow.up.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Text(
                """
                Conversion and uploading start now and continue photo \
                by photo. PickPic creates To Edit and Edited folders \
                beside your photos; the originals are never changed.
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
        if viewModel.isScanning
            || (
                viewModel.folderName == nil
                && viewModel.errorMessage == nil
            ) {
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
                    onChooseAnotherFolder()
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
                    onChooseAnotherFolder()
                }
            }
        }
    }
    
    private var proofSizeEstimate:
    UploadQueueStore.ProofSizeEstimate? {
        uploadQueue.estimatedProofSize(
            forPhotoCount: viewModel.photos.count
        )
    }
    
    /*
     * The size worth showing is what leaves the iPad, which is the
     * proofs rather than the originals — and that is also why it reads
     * as an approximation. Preflight drops duplicates once the pipeline
     * runs, so the real figure is usually a little lower, and the queue
     * reports it exactly.
     */
    private var uploadSizeFootnote: String {
        guard let estimate = proofSizeEstimate
        else {
            return """
            PickPic uploads a converted proof of each photo, not the \
            original file. Its size is known once conversion starts.
            """
        }
        
        let uploads =
        estimate.sampleJobCount == 1
        ? "your last upload"
        : "your last \(estimate.sampleJobCount) uploads"
        
        return """
        PickPic uploads a converted proof of each photo, not the \
        original file. Estimated from \(uploads); photos already in \
        the event are skipped, so the real total is often smaller.
        """
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
