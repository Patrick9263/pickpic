import SwiftUI

struct UploadQueueView: View {
    let event: PickPicEvent
    
    @EnvironmentObject private var uploadQueue:
    UploadQueueStore
    
    @State private var showingDeleteError = false
    @State private var deleteErrorMessage = ""
    
    private var eventJobs: [UploadJob] {
        uploadQueue.jobs(for: event.id)
    }
    
    var body: some View {
        List {
            ForEach(eventJobs) { job in
                UploadJobRow(
                    job: job,
                    onPrepare: {
                        Task {
                            await uploadQueue.prepare(
                                jobID: job.id
                            )
                        }
                    },
                    onConvertTest: {
                        Task {
                            await uploadQueue
                                .convertTestPreview(
                                    jobID: job.id
                                )
                        }
                    },
                    onConvertAll: {
                        Task {
                            await uploadQueue
                                .convertAllPhotos(
                                    jobID: job.id
                                )
                        }
                    }
                )
            }
            .onDelete(perform: deleteJobs)
        }
        .navigationTitle("Upload Queue")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if eventJobs.isEmpty {
                emptyState
            }
        }
        .alert(
            "Unable to Remove Upload",
            isPresented: $showingDeleteError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
    }
    
    @ViewBuilder
    private var emptyState: some View {
        if let loadErrorMessage =
            uploadQueue.loadErrorMessage {
            ContentUnavailableView {
                Label(
                    "Unable to Read Queue",
                    systemImage:
                        "exclamationmark.triangle"
                )
            } description: {
                Text(loadErrorMessage)
            }
        } else {
            ContentUnavailableView(
                "Upload Queue Is Empty",
                systemImage: "arrow.up.circle",
                description: Text(
                    """
                    Photos waiting, uploading, or needing \
                    attention will appear here.
                    """
                )
            )
        }
    }
    
    private func deleteJobs(
        at offsets: IndexSet
    ) {
        let selectedJobs = offsets.map { index in
            eventJobs[index]
        }
        
        guard
            !selectedJobs.contains(
                where: { job in
                    job.stage == .preparing
                    || job.stage == .converting
                    || job.stage == .uploading
                }
            )
        else {
            deleteErrorMessage =
                """
                Wait for the current operation to finish \
                before deleting this job.
                """
            showingDeleteError = true
            return
        }
        
        let jobIDs = Set(
            selectedJobs.map(\.id)
        )
        
        do {
            try uploadQueue.remove(
                jobIDs: jobIDs
            )
        } catch {
            deleteErrorMessage =
            error.localizedDescription
            
            showingDeleteError = true
        }
    }
}

private struct UploadJobRow: View {
    let job: UploadJob
    let onPrepare: () -> Void
    let onConvertTest: () -> Void
    let onConvertAll: () -> Void
    
    @State private var folderIsAccessible:
    Bool?
    
    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 10
        ) {
            HStack {
                Label(
                    job.stage.title,
                    systemImage:
                        job.stage.systemImage
                )
                .font(.headline)
                
                Spacer()
                
                Text(
                    job.createdAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Label(
                job.folderName,
                systemImage: "folder"
            )
            .lineLimit(1)
            
            HStack(spacing: 16) {
                Label(
                    "\(job.photoCount) photos",
                    systemImage:
                        "photo.on.rectangle.angled"
                )
                
                Text(
                    ByteCountFormatter.string(
                        fromByteCount:
                            job.totalBytes,
                        countStyle: .file
                    )
                )
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            
            folderAccessLabel
            preparationStatus
        }
        .padding(.vertical, 5)
        .task(id: job.updatedAt) {
            folderIsAccessible =
            FolderBookmarkService
                .canAccessFolder(
                    using:
                        job.folderBookmarkData
                )
        }
    }
    
    @ViewBuilder
    private var preparationStatus: some View {
        switch job.stage {
        case .queued:
            Button {
                onPrepare()
            } label: {
                Label(
                    "Prepare Upload",
                    systemImage:
                        "folder.badge.gearshape"
                )
            }
            .buttonStyle(.borderedProminent)
            
        case .preparing:
            HStack(spacing: 10) {
                ProgressView()
                
                Text(
                    "Creating To Edit and Edited…"
                )
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            
        case .prepared:
            Label(
                "Workflow folders are ready",
                systemImage: "checkmark.circle"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            
            if let preview =
                job.conversionPreview {
                Label(
                """
                Test JPEG: \(preview.pixelWidth) × \
                \(preview.pixelHeight)
                """,
                systemImage: "photo"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                
                NavigationLink {
                    ConversionPreviewView(
                        job: job
                    )
                } label: {
                    Label(
                        "View Test Preview",
                        systemImage:
                            "photo.on.rectangle"
                    )
                }
                
                Button {
                    onConvertTest()
                } label: {
                    Label(
                        "Reconvert Test Photo",
                        systemImage:
                            "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    onConvertTest()
                } label: {
                    Label(
                        "Convert Test Photo",
                        systemImage:
                            "photo.badge.arrow.down"
                    )
                }
                .buttonStyle(.bordered)
            }
            
            Button {
                onConvertAll()
            } label: {
                Label(
                    "Convert All Photos",
                    systemImage:
                        "rectangle.stack.badge.play"
                )
            }
            .buttonStyle(.borderedProminent)
            
            if let errorMessage =
                job.conversionErrorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            
        case .converting:
            VStack(
                alignment: .leading,
                spacing: 8
            ) {
                ProgressView(
                    value:
                        Double(
                            job.conversionProcessedCount
                        ),
                    total:
                        Double(
                            max(job.photoCount, 1)
                        )
                )
                
                Text(
                """
                \(job.conversionProcessedCount) of \
                \(job.photoCount) photos converted
                """
                )
                .font(.subheadline)
                
                if let filename =
                    job.conversionCurrentFilename {
                    Text(filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Text(
                """
                Reading metadata, hashing the original, \
                and creating the proof JPEG…
                """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
        case .readyToUpload:
            let capturedAtCount =
            job.preparedPhotos.filter { photo in
                photo.metadata.capturedAt != nil
            }
            .count
            
            let locationCount =
            job.preparedPhotos.filter { photo in
                photo.metadata.latitude != nil
                && photo.metadata.longitude
                != nil
            }
            .count
            
            Label(
            """
            \(job.preparedPhotos.count) JPEGs are ready
            """,
            systemImage:
                "tray.and.arrow.up.fill"
            )
            .font(.headline)
            
            LabeledContent(
                "Prepared size",
                value:
                    ByteCountFormatter.string(
                        fromByteCount:
                            job.preparedByteCount,
                        countStyle: .file
                    )
            )
            
            LabeledContent(
                "Capture times",
                value:
                    "\(capturedAtCount) of \(job.photoCount)"
            )
            
            LabeledContent(
                "Locations",
                value:
                    "\(locationCount) of \(job.photoCount)"
            )
            
            Text(
            """
            SHA-256 has been calculated from each \
            original source file.
            """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            
            Button {
                onConvertAll()
            } label: {
                Label(
                    "Reconvert All Photos",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            
        case .failed:
            if let errorMessage =
                job.errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            
            Button {
                onPrepare()
            } label: {
                Label(
                    "Try Preparation Again",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            
        case .uploading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Uploading…")
            }
            
        case .completed:
            Label(
                "Upload completed",
                systemImage:
                    "checkmark.circle.fill"
            )
        }
    }
    
    @ViewBuilder
    private var folderAccessLabel: some View {
        switch folderIsAccessible {
        case .none:
            Label(
                "Checking folder access…",
                systemImage: "ellipsis.circle"
            )
            .foregroundStyle(.secondary)
            
        case .some(true):
            Label(
                "Folder available",
                systemImage: "checkmark.circle"
            )
            .foregroundStyle(.secondary)
            
        case .some(false):
            Label(
                "Folder needs to be selected again",
                systemImage:
                    "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        }
    }
}
