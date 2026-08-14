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

    private var eventHasContinuedProcessing: Bool {
        eventJobs.contains { job in
            job.continuedProcessing?
                .isScheduledOrActive == true
        }
    }

    private var eventHasForegroundOnlyProcessing: Bool {
        eventJobs.contains { job in
            guard
                job.stage == .preparing
                    || job.stage == .preflighting
                    || job.stage == .converting
            else {
                return false
            }

            return job.continuedProcessing?
                .isScheduledOrActive != true
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
            if eventHasContinuedProcessing {
                Section {
                    Label(
                        "iPadOS background processing enabled",
                        systemImage: "gearshape.arrow.triangle.2.circlepath"
                    )
                    .font(.headline)

                    Text(
                        "PickPic has requested continued processing for this user-started batch. It can keep preparing and converting when you switch apps or lock the iPad, subject to iPadOS scheduling."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            } else if eventHasForegroundOnlyProcessing {
                Section {
                    Label(
                        "Keep PickPic open",
                        systemImage: "hourglass"
                    )
                    .font(.headline)

                    Text(
                        "This operation is running without an iPadOS continued-processing grant. Keep PickPic open until it reaches the background-upload phase."
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
                        || eventHasContinuedProcessing
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
                        uploadQueue
                            .startUserInitiatedUploadPipeline(
                                jobID: job.id,
                                using: configuration
                            )
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
                        uploadQueue
                            .startUserInitiatedReconversion(
                                jobID: job.id
                            )
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
                    onIncludeDuplicatesChanged: {
                        includesDuplicates in

                        uploadQueue
                            .setPreflightIncludesDuplicates(
                                includesDuplicates,
                                jobID: job.id
                            )
                    },
                    isRelinkingFolder:
                        relinkingJobID == job.id,
                    canRelinkFolder:
                        !job.stage.isActiveOperation
                        && job.continuedProcessing?
                            .isScheduledOrActive != true,
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
                    || job.stage == .preflighting
                    || job.stage == .converting
                    || job.stage == .uploading
                    || job.continuedProcessing?
                        .isScheduledOrActive == true
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
    let onIncludeDuplicatesChanged: (Bool) -> Void
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

    private var isContinuedProcessingScheduledOrActive: Bool {
        job.continuedProcessing?
            .isScheduledOrActive == true
    }

    private var statusTitle: String {
        if job.uploadProgress.isWaitingForConnectivity {
            return "Waiting for Network"
        }

        switch job.continuedProcessing?.status {
        case .scheduled:
            return "Waiting for iPadOS"

        case .active:
            return "Background Processing"

        case .deferred,
                .foregroundFallback,
                .none:
            return job.stage.title
        }
    }

    private var statusSystemImage: String {
        if job.uploadProgress.isWaitingForConnectivity {
            return "wifi.exclamationmark"
        }

        switch job.continuedProcessing?.status {
        case .scheduled:
            return "clock.badge.checkmark"

        case .active:
            return "gearshape.arrow.triangle.2.circlepath"

        case .deferred,
                .foregroundFallback,
                .none:
            return job.stage.systemImage
        }
    }
    
    /*
     * Duplicate preflight result.
     *
     * Shown before conversion so the photographer can see what will be
     * skipped and override it. Nothing is destructive here: including
     * duplicates just converts and uploads them as before, and the server
     * still rejects true duplicates.
     */
    @ViewBuilder
    private var preflightSummary: some View {
        if let preflight = job.preflight {
            if let errorMessage = preflight.errorMessage {
                Label(
                    errorMessage,
                    systemImage:
                        "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if preflight.duplicateCount > 0 {
                VStack(
                    alignment: .leading,
                    spacing: 6
                ) {
                    Label(
                        """
                        \(preflight.duplicateCount) of \
                        \(job.photoCount) photos are already in \
                        this event
                        """,
                        systemImage: "doc.on.doc"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    Toggle(
                        "Convert them anyway",
                        isOn: Binding(
                            get: {
                                !preflight
                                    .overriddenSourcePhotoIDs
                                    .isEmpty
                            },
                            set: { includesDuplicates in
                                onIncludeDuplicatesChanged(
                                    includesDuplicates
                                )
                            }
                        )
                    )
                    .font(.subheadline)
                    .disabled(
                        isContinuedProcessingScheduledOrActive
                    )

                    Text(
                        preflight.hasSkippableDuplicates
                        ? """
                        \(job.photosToConvertCount) photos will be \
                        converted and uploaded.
                        """
                        : """
                        All \(job.photoCount) photos will be \
                        converted. The server still skips exact \
                        duplicates on upload.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if preflight.unconfirmedCount > 0 {
                Text(
                    """
                    \(preflight.unconfirmedCount) photos share a \
                    filename with existing photos but could not be \
                    verified, so they will be converted.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 10
        ) {
            HStack {
                Label(
                    statusTitle,
                    systemImage:
                        statusSystemImage
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
            continuedProcessingNotice
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
    private var continuedProcessingNotice: some View {
        if let processing = job.continuedProcessing {
            switch processing.status {
            case .scheduled:
                Label(
                    "Waiting for iPadOS to begin",
                    systemImage: "clock.badge.checkmark"
                )
                .font(.subheadline.weight(.semibold))

                Text(
                    processing.message
                    ?? "The request is queued and will begin as soon as iPadOS permits it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

            case .active:
                Label(
                    "Continues in the background",
                    systemImage: "gearshape.arrow.triangle.2.circlepath"
                )
                .font(.subheadline.weight(.semibold))

                Text(
                    processing.message
                    ?? "You can switch apps or lock the iPad while PickPic reports conversion progress to iPadOS."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

            case .deferred:
                Label(
                    "Background processing deferred",
                    systemImage: "pause.circle"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

                Text(
                    processing.message
                    ?? "Saved conversions are ready to resume."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

            case .foregroundFallback:
                Label(
                    "Background processing unavailable",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

                Text(
                    processing.message
                    ?? "Keep PickPic open until conversion finishes."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
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
            .disabled(
                isContinuedProcessingScheduledOrActive
            )
            
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
            .disabled(
                isContinuedProcessingScheduledOrActive
            )
            
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
            
        case .preflighting:
            HStack(spacing: 10) {
                ProgressView()
                Text(
                    "Checking which photos are already uploaded…"
                )
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

        case .prepared:
            preflightSummary

            if job.preparedPhotos.isEmpty {
                Label(
                    "Workflow folders are ready",
                    systemImage: "checkmark.circle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    """
                    \(job.preparedPhotos.count) of \
                    \(job.photoCount) proof JPEGs recovered
                    """,
                    systemImage:
                        "clock.arrow.circlepath"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            
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
                .disabled(
                    isContinuedProcessingScheduledOrActive
                )
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
                .disabled(
                    isContinuedProcessingScheduledOrActive
                )
            }
            
            Button {
                onContinue()
            } label: {
                Label(
                    job.preparedPhotos.isEmpty
                        ? "Continue Upload"
                        : "Resume Conversion and Upload",
                    systemImage:
                        "arrow.up.circle.fill"
                )
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isContinuedProcessingScheduledOrActive
            )
            
            Text(
                job.preparedPhotos.isEmpty
                    ? "Converts the full batch and begins uploading automatically."
                    : "Reuses the recovered JPEGs, converts only the remaining photos, and then resumes uploading."
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
                            max(
                                job.photosToConvertCount,
                                1
                            )
                        )
                )

                Text(
                    """
                    \(job.conversionProcessedCount) of \
                    \(job.photosToConvertCount) photos converted
                    """
                )
                .font(.subheadline)

                if job.preflightSkippedPhotoCount > 0 {
                    Text(
                        """
                        \(job.preflightSkippedPhotoCount) already \
                        uploaded, skipped
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
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
                        job.uploadProgress
                            .isWaitingForConnectivity
                        ? "Waiting for Network"
                        : "Upload stopped",
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
                            job.uploadProgress
                                .isWaitingForConnectivity
                            ? "Retry Now"
                            : "Retry This Photo",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            } else if
                job.uploadProgress
                    .isWaitingForConnectivity
            {
                Label(
                    "Waiting for an internet connection",
                    systemImage: "wifi.exclamationmark"
                )
                .font(.headline)
                .foregroundStyle(.orange)

                Text(
                    job.uploadProgress.errorMessage
                    ?? "PickPic will retry automatically when the connection is usable."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                HStack(spacing: 8) {
                    Image(
                        systemName:
                            job.uploadedPhotoCount > 0
                                || job.uploadProgress.pausedAt != nil
                            ? "play.fill"
                            : "arrow.up.circle.fill"
                    )

                    Text(
                        job.uploadedPhotoCount > 0
                            || job.uploadProgress.pausedAt != nil
                        ? "Resume Upload"
                        : "Upload Photos"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isContinuedProcessingScheduledOrActive
            )
            
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
            .disabled(
                job.uploadProgress
                    .isWaitingForConnectivity
                || isContinuedProcessingScheduledOrActive
            )
            
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

                if job.uploadProgress
                    .activeBackgroundTransfer != nil
                {
                    Label(
                        "iPadOS background upload active",
                        systemImage: "arrow.up.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))

                    Text(
                        "The current file can continue uploading when PickPic is backgrounded or the iPad locks, subject to iPadOS scheduling."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if job.uploadProgress
                    .isWaitingForConnectivity {
                    Label(
                        "Waiting for an internet connection",
                        systemImage: "wifi.exclamationmark"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                    if let waitingSince =
                        job.uploadProgress
                            .waitingForConnectivitySince {
                        Text(
                            "Waiting since \(waitingSince.formatted(date: .omitted, time: .shortened)). PickPic will continue automatically when the connection is usable."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    uploadProgressDetails(
                        at: Date(),
                        showsEstimate: false
                    )
                } else {
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
                        /*
                         * Stacked at this call site only. A TimelineView
                         * takes a single view, so the several rows this
                         * returns were handed one frame and drew over
                         * each other. The other callers put it straight
                         * into a stack, where wrapping it would instead
                         * collapse the rows into one.
                         */
                        VStack(
                            alignment: .leading,
                            spacing: 4
                        ) {
                            uploadProgressDetails(
                                at: context.date,
                                showsEstimate: true
                            )
                        }
                    }

                    Text(
                        "Average speed includes the proof JPEG plus thumbnail and preview processing."
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Button {
                    onPause()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pause.fill")
                        Text(
                            job.uploadProgress
                                .isWaitingForConnectivity
                            ? "Pause When Connected"
                            : "Pause Upload"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(
                    job.uploadProgress.isPauseRequested
                )
                .transaction { transaction in
                    transaction.animation = nil
                }

                if job.uploadProgress.isPauseRequested {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)

                        Text(
                            job.uploadProgress
                                .isWaitingForConnectivity
                            ? "PickPic will pause after the waiting photo finishes."
                            : "Finishing the current photo before pausing…"
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
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

            if job.preflightSkippedPhotoCount > 0 {
                Text(
                    job.preflightSkippedPhotoCount == 1
                    ? "1 already-existing photo skipped conversion entirely."
                    : "\(job.preflightSkippedPhotoCount) already-existing photos skipped conversion entirely."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if job.duplicatePhotoCount > 0 {
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
        VStack(
            alignment: .leading,
            spacing: 4
        ) {
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
                        < job.photosToConvertCount
                {
                    let averageSecondsPerPhoto =
                    elapsed / Double(
                        job.conversionProcessedCount
                    )

                    let remaining =
                    averageSecondsPerPhoto
                    * Double(
                        job.photosToConvertCount
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
                "\(job.alreadyExistedPhotoCount)"
        )

        LabeledContent(
            "Optimized",
            value:
                "\(job.optimizedPhotoCount)"
        )

        /*
         * Counts down the photos this job will actually convert, so a job
         * whose duplicates were all skipped by preflight reaches zero
         * instead of stalling at the full selection count.
         */
        LabeledContent(
            "Remaining",
            value:
                "\(max(job.photosToConvertCount - job.uploadedPhotoCount, 0))"
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
