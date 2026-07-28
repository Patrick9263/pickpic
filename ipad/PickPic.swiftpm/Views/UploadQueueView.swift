import SwiftUI
import UniformTypeIdentifiers

struct UploadQueueView: View {
    let event: PickPicEvent
    
    @EnvironmentObject private var uploadQueue:
    UploadQueueStore
    
    @EnvironmentObject private var configuration:
    APIConfigurationStore

    @EnvironmentObject private var eventFolders:
    EventFolderStore
    
    @State private var showingDeleteError = false
    @State private var deleteErrorMessage = ""

    @State private var relinkingJobID: UUID?
    @State private var showingFolderRelinker = false
    @State private var showingRelinkError = false
    @State private var relinkErrorMessage = ""
    
    private var eventJobs: [UploadJob] {
        uploadQueue.jobs(for: event.id)
    }

    private var incompleteEventJobs: [UploadJob] {
        eventJobs.filter { job in
            job.stage != .completed
        }
    }

    private var isRetryingIncompleteJobs: Bool {
        uploadQueue.isRetryingIncompleteJobs(
            for: event.id
        )
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
            if
                let message =
                    uploadQueue.recoveryMessage,
                !eventJobs.isEmpty
            {
                Section {
                    Label(
                        message,
                        systemImage:
                            "clock.arrow.circlepath"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            
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

            if incompleteEventJobs.count > 1 {
                Section {
                    Button {
                        Task {
                            await uploadQueue
                                .retryIncompleteJobs(
                                    for: event.id,
                                    using: configuration
                                )
                        }
                    } label: {
                        if isRetryingIncompleteJobs {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Continuing Uploads…")
                            }
                        } else {
                            Label(
                                "Retry All Incomplete",
                                systemImage:
                                    "arrow.clockwise.circle"
                            )
                        }
                    }
                    .disabled(
                        isRetryingIncompleteJobs
                        || eventHasActiveProcessing
                    )

                    Text(
                        "Continues each unfinished batch in order while preserving completed photos."
                    )
                    .font(.caption)
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
                    },
                    onPause: {
                        uploadQueue.requestPause(
                            jobID: job.id
                        )
                    },
                    onRetryFailedPhoto: {
                        Task {
                            await uploadQueue
                                .retryLastFailedPhoto(
                                    jobID: job.id,
                                    using: configuration
                                )
                        }
                    },
                    isRelinkingFolder:
                        relinkingJobID == job.id,
                    canRelinkFolder:
                        !job.stage.isActiveOperation,
                    onRelinkFolder: {
                        relinkingJobID = job.id
                        showingFolderRelinker = true
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
        .fileImporter(
            isPresented: $showingFolderRelinker,
            allowedContentTypes: [.folder]
        ) { result in
            handleFolderRelink(result)
        }
        .alert(
            "Unable to Remove Upload",
            isPresented: $showingDeleteError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
        .alert(
            "Unable to Relink Folder",
            isPresented: $showingRelinkError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(relinkErrorMessage)
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

    private func handleFolderRelink(
        _ result: Result<URL, Error>
    ) {
        guard let relinkingJobID else {
            return
        }

        switch result {
        case let .success(folderURL):
            Task {
                do {
                    let updatedJob = try await uploadQueue
                        .relinkFolder(
                            for: relinkingJobID,
                            to: folderURL
                        )

                    try eventFolders.save(
                        job: updatedJob
                    )

                    self.relinkingJobID = nil
                } catch {
                    relinkErrorMessage =
                        error.localizedDescription
                    showingRelinkError = true
                    self.relinkingJobID = nil
                }
            }

        case let .failure(error):
            self.relinkingJobID = nil

            if error is CancellationError {
                return
            }

            if let cocoaError = error as? CocoaError,
               cocoaError.code == .userCancelled {
                return
            }

            relinkErrorMessage =
                error.localizedDescription
            showingRelinkError = true
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
    let onPause: () -> Void
    let onRetryFailedPhoto: () -> Void
    let isRelinkingFolder: Bool
    let canRelinkFolder: Bool
    let onRelinkFolder: () -> Void
    
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

                TimelineView(
                    .periodic(
                        from: .now,
                        by: 1
                    )
                ) { context in
                    conversionTiming(
                        at: context.date
                    )
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
            if let pausedAt =
                job.uploadProgress.pausedAt {
                Label(
                    "Upload paused",
                    systemImage: "pause.circle.fill"
                )
                .font(.headline)

                Text(
                    "Paused after the current photo at \(pausedAt.formatted(date: .omitted, time: .shortened)). Completed photos were preserved."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Label(
                """
                \(job.preparedPhotos.count) JPEGs are ready
                """,
                systemImage:
                    "tray.and.arrow.up.fill"
            )
            .font(.headline)

            if job.uploadedPhotoCount > 0 {
                uploadProgressDetails(
                    at: Date(),
                    showsEstimate: false
                )
            }
            
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
            
            if let failure =
                job.uploadProgress.lastFailure {
                VStack(
                    alignment: .leading,
                    spacing: 8
                ) {
                    Label(
                        "Upload stopped",
                        systemImage:
                            failure.isNetworkRelated
                            ? "wifi.exclamationmark"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(.orange)

                    Text(failure.sourceFilename)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(failure.step.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(failure.message)
                        .font(.subheadline)
                        .foregroundStyle(.red)

                    Button {
                        onRetryFailedPhoto()
                    } label: {
                        Label(
                            "Retry This Photo",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            } else if let errorMessage =
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
                    \(job.photoCount) photos complete
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
                    job.uploadProgress.currentStep?.title
                    ?? "Uploading prepared JPEG…"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                TimelineView(
                    .periodic(
                        from: .now,
                        by: 1
                    )
                ) { context in
                    uploadProgressDetails(
                        at: context.date,
                        showsEstimate: true
                    )
                }

                Text(
                    "Average speed includes the proof JPEG plus thumbnail and preview processing."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)

                Button {
                    onPause()
                } label: {
                    Label(
                        job.uploadProgress.isPauseRequested
                        ? "Pausing After This Photo…"
                        : "Pause Upload",
                        systemImage:
                            job.uploadProgress.isPauseRequested
                            ? "hourglass"
                            : "pause.circle"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(
                    job.uploadProgress.isPauseRequested
                )
            }
            
        case .completed:
            Label(
                "Upload complete",
                systemImage:
                    "checkmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(.green)

            uploadProgressDetails(
                at:
                    job.uploadProgress.completedAt
                    ?? job.updatedAt,
                showsEstimate: false
            )

            LabeledContent(
                "Failed",
                value: "0"
            )

            if job.duplicatePhotoCount > 0 {
                Text(
                    "Already-existing photos skipped a duplicate full upload."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            if let completedAt =
                job.uploadProgress.completedAt {
                Text(
                    "Finished \(completedAt.formatted(date: .abbreviated, time: .shortened))"
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
    private func conversionTiming(
        at date: Date
    ) -> some View {
        if let startedAt =
            job.conversionStartedAt {
            let elapsed = max(
                date.timeIntervalSince(
                    startedAt
                ),
                0
            )

            LabeledContent(
                "Elapsed",
                value:
                    formattedDuration(elapsed)
            )

            if
                job.conversionProcessedCount > 0,
                job.conversionProcessedCount
                    < job.photoCount
            {
                let averageSecondsPerPhoto =
                elapsed / Double(
                    job.conversionProcessedCount
                )

                let remaining =
                averageSecondsPerPhoto
                * Double(
                    job.photoCount
                    - job.conversionProcessedCount
                )

                LabeledContent(
                    "Estimated remaining",
                    value:
                        "About \(formattedDuration(remaining))"
                )
            }
        }
    }

    @ViewBuilder
    private func uploadProgressDetails(
        at date: Date,
        showsEstimate: Bool
    ) -> some View {
        LabeledContent(
            "New uploads",
            value:
                "\(job.newlyUploadedPhotoCount)"
        )

        LabeledContent(
            "Already existed",
            value:
                "\(job.duplicatePhotoCount)"
        )

        LabeledContent(
            "Optimized",
            value:
                "\(job.optimizedPhotoCount)"
        )

        LabeledContent(
            "Remaining",
            value:
                "\(max(job.photoCount - job.uploadedPhotoCount, 0))"
        )

        let elapsed = job.uploadElapsedDuration(
            at: date
        )

        if elapsed > 0 {
            LabeledContent(
                "Active elapsed",
                value:
                    formattedDuration(elapsed)
            )
        }

        if let bytesPerSecond =
            job.averageUploadBytesPerSecond(
                at: date
            )
        {
            LabeledContent(
                "Average speed",
                value:
                    formattedByteRate(
                        bytesPerSecond
                    )
            )
        }

        if
            showsEstimate,
            let remainingDuration =
                job.estimatedUploadRemainingDuration(
                    at: date
                )
        {
            LabeledContent(
                "Estimated remaining",
                value:
                    "About \(formattedDuration(remainingDuration))"
            )
        }
    }

    private func formattedDuration(
        _ duration: TimeInterval
    ) -> String {
        let totalSeconds = max(
            Int(duration.rounded()),
            0
        )

        let hours = totalSeconds / 3_600
        let minutes =
        (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }

        return "\(seconds)s"
    }

    private func formattedByteRate(
        _ bytesPerSecond: Double
    ) -> String {
        let formatted = ByteCountFormatter.string(
            fromByteCount:
                Int64(bytesPerSecond),
            countStyle: .file
        )

        return "\(formatted)/s"
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
            HStack {
                Label(
                    "Folder available",
                    systemImage:
                        "checkmark.circle"
                )
                .foregroundStyle(.secondary)

                Spacer()

                if isRelinkingFolder {
                    ProgressView()
                } else {
                    Button("Change") {
                        onRelinkFolder()
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canRelinkFolder)
                }
            }

            if !canRelinkFolder {
                Text(
                    "Folder changes are disabled while PickPic is processing this batch."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
        case .some(false):
            VStack(
                alignment: .leading,
                spacing: 8
            ) {
                Label(
                    "Folder needs to be selected again",
                    systemImage:
                        "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)

                Button {
                    onRelinkFolder()
                } label: {
                    if isRelinkingFolder {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Relinking…")
                        }
                    } else {
                        Label(
                            "Relink Event Folder",
                            systemImage:
                                "folder.badge.plus"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(
                    isRelinkingFolder
                    || !canRelinkFolder
                )

                if !canRelinkFolder {
                    Text(
                        "Wait for the current operation to pause or finish before relinking."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}
