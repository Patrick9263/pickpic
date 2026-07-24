import SwiftUI

struct UploadQueueView: View {
    let event: PickPicEvent
    
    @EnvironmentObject private var uploadQueue:
    UploadQueueStore
    
    @EnvironmentObject private var configuration:
    APIConfigurationStore
    
    @State private var showingDeleteError = false
    @State private var deleteErrorMessage = ""
    
    private var eventJobs: [UploadJob] {
        uploadQueue.jobs(for: event.id)
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
            if let message =
                uploadQueue.storageCleanupMessage {
                Section {
                    Label(
                        message,
                        systemImage:
                            "externaldrive.badge.checkmark"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            
            if let message =
                uploadQueue.storageErrorMessage {
                Section {
                    Label(
                        message,
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            if eventHasActiveProcessing {
                Section {
                    Label(
                        "Keep PickPic open",
                        systemImage: "hourglass"
                    )
                    .font(.headline)
                    Text(
                        """
                        Folder preparation, conversion, and uploads \
                        currently run in the foreground. Keep PickPic \
                        open, and temporarily increase Auto-Lock for \
                        longer batches.
                        """
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(eventJobs) { job in
                UploadJobRow(
                    job: job,
                    onContinue: {
                        Task {
                            await uploadQueue
                                .runUploadPipeline(
                                    jobID: job.id,
                                    using: configuration
                                )
                        }
                    },
                    onTestFirstPhoto: {
                        Task {
                            await uploadQueue
                                .runTestPreviewPipeline(
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
    
    let onContinue: () -> Void
    let onTestFirstPhoto: () -> Void
    let onConvertAll: () -> Void
    
    @State private var folderIsAccessible:
    Bool?
    
    private var capturedAtCount: Int {
        job.preparedPhotos.filter { photo in
            photo.metadata.capturedAt != nil
        }
        .count
    }
    
    private var locationCount: Int {
        job.preparedPhotos.filter { photo in
            photo.metadata.latitude != nil
            && photo.metadata.longitude != nil
        }
        .count
    }
    
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
                onContinue()
            } label: {
                Label(
                    "Start Upload",
                    systemImage:
                        "arrow.up.circle.fill"
                )
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            
            Button {
                onTestFirstPhoto()
            } label: {
                Label(
                    "Test First Photo",
                    systemImage: "photo"
                )
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            
            Text(
                """
                Start Upload runs the complete batch. Test First \
                Photo prepares the folders and creates one preview \
                without uploading the event.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            
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
            
            if let preview = job.conversionPreview {
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
                        systemImage: "eye"
                    )
                    .labelStyle(.titleAndIcon)
                }
                
                Button {
                    onTestFirstPhoto()
                } label: {
                    Label(
                        "Reconvert Test Photo",
                        systemImage: "arrow.clockwise"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    onTestFirstPhoto()
                } label: {
                    Label(
                        "Convert Test Photo",
                        systemImage: "photo"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
            }
            
            Button {
                onContinue()
            } label: {
                Label(
                    "Continue Upload",
                    systemImage:
                        "arrow.up.circle.fill"
                )
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            
            Text(
                """
                Converts the full batch and begins uploading \
                automatically.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            
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
            
            if job.uploadedPhotoCount > 0 {
                ProgressView(
                    value:
                        Double(
                            job.uploadedPhotoCount
                        ),
                    total:
                        Double(
                            max(job.photoCount, 1)
                        )
                )
                
                Text(
                    """
                    \(job.uploadedPhotoCount) of \
                    \(job.photoCount) already uploaded
                    """
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                
                if job.duplicatePhotoCount > 0 {
                    Text(
                        """
                        \(job.duplicatePhotoCount) matched \
                        existing server photos.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            
            if let errorMessage =
                job.uploadProgress.errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            
            if let errorMessage =
                job.conversionErrorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            
            if job.conversionPreview != nil {
                NavigationLink {
                    ConversionPreviewView(
                        job: job
                    )
                } label: {
                    Label(
                        "View Test Preview",
                        systemImage: "eye"
                    )
                    .labelStyle(.titleAndIcon)
                }
            }
            
            Button {
                onContinue()
            } label: {
                Label(
                    job.uploadedPhotoCount > 0
                    ? "Resume Upload"
                    : "Upload Photos",
                    systemImage:
                        "arrow.up.circle.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            
            Button {
                onConvertAll()
            } label: {
                Label(
                    "Reconvert All Photos",
                    systemImage:
                        "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            
        case .uploading:
            VStack(
                alignment: .leading,
                spacing: 8
            ) {
                ProgressView(
                    value:
                        Double(
                            job.uploadedPhotoCount
                        ),
                    total:
                        Double(
                            max(job.photoCount, 1)
                        )
                )
                
                Text(
                    """
                    \(job.uploadedPhotoCount) of \
                    \(job.photoCount) photos uploaded
                    """
                )
                .font(.subheadline)
                
                if let filename =
                    job.uploadProgress
                    .currentFilename {
                    Text(filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Text(
                    "Uploading prepared JPEG…"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
        case .completed:
            Label(
                """
                \(job.uploadedPhotoCount) photos uploaded
                """,
                systemImage:
                    "checkmark.circle.fill"
            )
            .font(.headline)
            
            if job.duplicatePhotoCount > 0 {
                Label(
                    """
                    \(job.duplicatePhotoCount) were \
                    already present
                    """,
                    systemImage:
                        "rectangle.on.rectangle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            
            if let completedAt =
                job.uploadProgress.completedAt {
                Text(
                    completedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
        case .failed:
            if let errorMessage =
                job.errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            
            Button {
                onContinue()
            } label: {
                Label(
                    "Try Upload Again",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.borderedProminent)
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
