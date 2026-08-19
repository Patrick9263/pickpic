import SwiftUI
import UniformTypeIdentifiers

struct FinalUploadsView: View {
    let event: PickPicEvent
    let automaticallyUploadReadyFinals: Bool

    init(
        event: PickPicEvent,
        automaticallyUploadReadyFinals: Bool = false
    ) {
        self.event = event
        self.automaticallyUploadReadyFinals =
        automaticallyUploadReadyFinals
    }
    
    @EnvironmentObject private var configuration:
    APIConfigurationStore
    
    @EnvironmentObject private var eventFolders:
    EventFolderStore

    @EnvironmentObject private var feedback:
    AppFeedbackStore
    
    @EnvironmentObject private var finishedEdits:
    FinishedEditsWatcher

    @StateObject private var viewModel =
    FinalUploadsViewModel()

    @State private var showingFolderPicker = false
    @State private var hasAttemptedAutomaticUpload = false
    
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
            
            if let scanResult =
                viewModel.scanResult {
                summarySection(scanResult)
                readyFinalsSection(scanResult)
                variantRepairsSection(scanResult)
                issuesSection(scanResult)
            } else if viewModel.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView(
                            "Scanning Edited…"
                        )
                        Spacer()
                    }
                }
            }
            
            if
                (viewModel.lastUploadedCount ?? 0) > 0
                || (viewModel.lastOptimizedCount ?? 0) > 0
            {
                lastOperationSection
            }
            
            if !viewModel.variantUploadFailures.isEmpty {
                Section("Optimization Needs Retry") {
                    Label(
            """
            Full final images were uploaded, but some \
            optimized images need another attempt.
            """,
            systemImage:
                "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    
                    ForEach(
                        viewModel.variantUploadFailures,
                        id: \.self
                    ) { filename in
                        Text(filename)
                            .font(.caption)
                    }
                }
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
        }
        .navigationTitle("Upload Finals")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await reload()
            await startAutomaticUploadIfNeeded()
        }
        .safeAreaInset(edge: .bottom) {
            if
                let folderReference,
                let scanResult =
                    viewModel.scanResult,
                !scanResult.candidates.isEmpty
                    || !scanResult
                    .variantRepairCandidates
                    .isEmpty
            {
                uploadControls(
                    scanResult: scanResult,
                    reference: folderReference
                )
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
        .task(id: folderReference?.updatedAt) {
            await reload()
            await startAutomaticUploadIfNeeded()
        }
        /*
         * This screen and the app-level watcher drive the same Edited
         * folder through separate view models, so the watch stands down
         * while the explicit screen is open rather than both uploading
         * the same file.
         */
        .onAppear {
            finishedEdits.suspend()
        }
        .onDisappear {
            finishedEdits.resume()
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
                
                Text(
                    """
                    Final JPEGs are matched from the \
                    Edited folder using their basename.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                
                Text(
                    """
                    Example: DSC01234.ARW matches \
                    Edited/DSC01234.jpg
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                
                Button("Change Event Folder") {
                    showingFolderPicker = true
                }
                .disabled(viewModel.isUploading)
            } else {
                Text(
                    """
                    Select the folder containing this \
                    event's original RAW files, To Edit, \
                    and Edited folders.
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
    
    private func summarySection(
        _ result: FinalUploadScanResult
    ) -> some View {
        Section("Summary") {
            LabeledContent(
                "Waiting for finals",
                value:
                    "\(result.eligiblePhotoCount)"
            )
            
            LabeledContent(
                "Ready to upload",
                value:
                    "\(result.candidates.count)"
            )
            
            LabeledContent(
                "Missing edited JPEGs",
                value:
                    "\(result.missingSourceFilenames.count)"
            )
            
            LabeledContent(
                "Needs optimization",
                value:
                    "\(result.variantRepairCandidates.count)"
            )
        }
    }
    
    private func readyFinalsSection(
        _ result: FinalUploadScanResult
    ) -> some View {
        Section(
            "Ready Finals (\(result.candidates.count))"
        ) {
            if result.candidates.isEmpty {
                Text(
                    """
                    No edited JPEGs currently match \
                    photos waiting for finals.
                    """
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(result.candidates) {
                    candidate in
                    
                    VStack(
                        alignment: .leading,
                        spacing: 6
                    ) {
                        HStack {
                            Text(
                                candidate
                                    .editedFilename
                            )
                            .lineLimit(1)
                            
                            Spacer()
                            
                            if candidate.isReplacement {
                                Text("Replacement")
                                    .font(.caption)
                                    .foregroundStyle(
                                        .secondary
                                    )
                            }
                        }
                        
                        Text(
                            """
                            From \(candidate.sourceFilename)
                            """
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount:
                                    candidate.byteSize,
                                countStyle: .file
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
    
    @ViewBuilder
    private func issuesSection(
        _ result: FinalUploadScanResult
    ) -> some View {
        if
            !result.missingSourceFilenames.isEmpty
                || !result
                .ambiguousMatches.isEmpty
                || !result
                .oversizedEditedFilenames.isEmpty
                || !result
                .unmatchedEditedFilenames.isEmpty
        {
            Section("Needs Attention") {
                issueGroup(
                    title:
                        "Missing from Edited",
                    values:
                        result
                        .missingSourceFilenames,
                    systemImage:
                        "photo.badge.plus"
                )
                
                issueGroup(
                    title:
                        "Ambiguous matches",
                    values:
                        result.ambiguousMatches,
                    systemImage:
                        "questionmark.folder"
                )
                
                issueGroup(
                    title:
                        "Over 50 MB",
                    values:
                        result
                        .oversizedEditedFilenames,
                    systemImage:
                        "externaldrive.badge.exclamationmark"
                )
                
                issueGroup(
                    title:
                        "Unmatched files in Edited",
                    values:
                        result
                        .unmatchedEditedFilenames,
                    systemImage:
                        "questionmark.diamond"
                )
            }
        }
    }
    
    @ViewBuilder
    private func issueGroup(
        title: String,
        values: [String],
        systemImage: String
    ) -> some View {
        if !values.isEmpty {
            VStack(
                alignment: .leading,
                spacing: 6
            ) {
                Label(
                    "\(title) (\(values.count))",
                    systemImage: systemImage
                )
                .foregroundStyle(.orange)
                
                ForEach(values, id: \.self) {
                    value in
                    
                    Text(value)
                        .font(.caption)
                }
            }
        }
    }
    
    private func uploadControls(
        scanResult: FinalUploadScanResult,
        reference: EventFolderReference
    ) -> some View {
        VStack(spacing: 10) {
            if
                viewModel.isUploading
                    || viewModel.isRepairingVariants
            {
                let completedCount =
                viewModel.completedOperationCount

                let totalCount = max(
                    viewModel.operationTotalCount,
                    1
                )
                
                ProgressView(
                    value:
                        Double(completedCount),
                    total:
                        Double(totalCount)
                )
                
                Text(
                    "\(completedCount) of \(viewModel.operationTotalCount) complete"
                )
                .font(.subheadline)
                
                if let currentStep =
                    viewModel.currentStep {
                    Text(currentStep)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let filename =
                    viewModel.currentFilename {
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
                    activeOperationMetrics(
                        at: context.date
                    )
                }
            }
            
            if !scanResult.candidates.isEmpty {
                Button {
                    Task {
                        await uploadFinals(
                            reference: reference
                        )
                    }
                } label: {
                    Label(
                    """
                    Upload \(scanResult.candidates.count) \
                    \(scanResult.candidates.count == 1
                        ? "Final"
                        : "Finals")
                    """,
                    systemImage:
                        "arrow.up.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isBusy)
            }
            
            if
                !scanResult
                    .variantRepairCandidates
                    .isEmpty
            {
                Button {
                    Task {
                        await repairFinalVariants(
                            reference: reference
                        )
                    }
                } label: {
                    Label(
                    """
                    Optimize \
                    \(scanResult.variantRepairCandidates.count) \
                    Existing \
                    \(scanResult.variantRepairCandidates.count == 1
                        ? "Final"
                        : "Finals")
                    """,
                    systemImage:
                        "photo.stack"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(viewModel.isBusy)
            }
        }
        .padding()
        .background(.regularMaterial)
    }
    
    private func variantRepairsSection(
        _ result: FinalUploadScanResult
    ) -> some View {
        Section(
        """
        Finals Needing Optimized Images \
        (\(result.variantRepairCandidates.count))
        """
        ) {
            if result.variantRepairCandidates.isEmpty {
                Text(
                """
                All matching final images have thumbnails \
                and previews.
                """
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(
                    result.variantRepairCandidates
                ) { candidate in
                    VStack(
                        alignment: .leading,
                        spacing: 5
                    ) {
                        Text(candidate.editedFilename)
                        
                        Text(
                        """
                        Full final is already uploaded. \
                        Thumbnail and preview are missing.
                        """
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    
    private var lastOperationSection: some View {
        Section(
            viewModel.lastOperationWasVariantRepair
            ? "Last Optimization"
            : "Last Final Upload"
        ) {
            if viewModel.lastOperationWasVariantRepair {
                Label(
                    viewModel.lastOperationSucceeded
                    ? "Optimization complete"
                    : "Optimization stopped",
                    systemImage:
                        viewModel.lastOperationSucceeded
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(
                    viewModel.lastOperationSucceeded
                    ? Color.green
                    : Color.orange
                )

                LabeledContent(
                    "Optimized",
                    value:
                        "\(viewModel.lastOptimizedCount ?? 0)"
                )
            } else {
                Label(
                    viewModel.lastOperationSucceeded
                    ? "Final upload complete"
                    : "Final upload stopped",
                    systemImage:
                        viewModel.lastOperationSucceeded
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(
                    viewModel.lastOperationSucceeded
                    ? Color.green
                    : Color.orange
                )

                LabeledContent(
                    "Uploaded finals",
                    value:
                        "\(viewModel.lastUploadedCount ?? 0)"
                )

                LabeledContent(
                    "Optimized",
                    value:
                        "\(viewModel.lastOptimizedCount ?? 0)"
                )

                LabeledContent(
                    "Optimization retries",
                    value:
                        "\(viewModel.variantUploadFailures.count)"
                )
            }

            LabeledContent(
                "Failed",
                value:
                    viewModel.lastOperationSucceeded
                    ? "0"
                    : "1"
            )

            if let duration =
                viewModel.lastOperationDuration {
                LabeledContent(
                    "Elapsed",
                    value:
                        formattedDuration(duration)
                )

                if
                    duration > 0.5,
                    viewModel.lastProcessedByteCount > 0
                {
                    let bytesPerSecond =
                    Double(
                        viewModel.lastProcessedByteCount
                    ) / duration

                    LabeledContent(
                        "Average speed",
                        value:
                            formattedByteRate(
                                bytesPerSecond
                            )
                    )
                }
            }
        }
    }

    /*
     * Stacked here rather than left to the caller. These are several
     * sibling views from a ViewBuilder, and the TimelineView that shows
     * them takes a single view, so without a stack they were all handed
     * the same frame and drew on top of one another.
     */
    private func activeOperationMetrics(
        at date: Date
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 4
        ) {
            if let elapsed =
                viewModel.operationElapsedDuration(
                    at: date
                )
            {
                LabeledContent(
                    "Elapsed",
                    value:
                        formattedDuration(elapsed)
                )
            }

            if let bytesPerSecond =
                viewModel.averageOperationBytesPerSecond(
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

            if let remaining =
                viewModel.estimatedOperationRemainingDuration(
                    at: date
                )
            {
                LabeledContent(
                    "Estimated remaining",
                    value:
                        "About \(formattedDuration(remaining))"
                )
            }
        }
    }

    private func uploadFinals(
        reference: EventFolderReference
    ) async {
        await viewModel.uploadAll(
            eventID: event.id,
            reference: reference,
            using: configuration
        )

        guard
            viewModel.lastOperationSucceeded,
            let uploadedCount =
                viewModel.lastUploadedCount,
            uploadedCount > 0
        else {
            return
        }

        let optimizedCount =
        viewModel.lastOptimizedCount
        ?? 0

        let retryCount =
        viewModel.variantUploadFailures.count

        let retryDetail =
        retryCount > 0
        ? ", \(retryCount) need optimization retry"
        : ""

        feedback.show(
            title: "Final upload complete",
            detail:
                "\(event.title): \(uploadedCount) uploaded, \(optimizedCount) optimized\(retryDetail).",
            systemImage: "checkmark.circle.fill"
        )
    }

    private func repairFinalVariants(
        reference: EventFolderReference
    ) async {
        await viewModel.repairMissingVariants(
            eventID: event.id,
            reference: reference,
            using: configuration
        )

        guard
            viewModel.lastOperationSucceeded,
            let optimizedCount =
                viewModel.lastOptimizedCount,
            optimizedCount > 0
        else {
            return
        }

        feedback.show(
            title: "Final images optimized",
            detail:
                "\(event.title): repaired \(optimizedCount) final \(optimizedCount == 1 ? "image" : "images").",
            systemImage: "checkmark.circle.fill"
        )
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

    private func startAutomaticUploadIfNeeded() async {
        guard
            automaticallyUploadReadyFinals,
            !hasAttemptedAutomaticUpload,
            let folderReference,
            let scanResult = viewModel.scanResult,
            !scanResult.candidates.isEmpty,
            !viewModel.isBusy
        else {
            return
        }

        hasAttemptedAutomaticUpload = true

        await uploadFinals(
            reference: folderReference
        )
    }

    private func reload() async {
        guard let folderReference else {
            return
        }
        
        await viewModel.load(
            eventID: event.id,
            reference: folderReference,
            using: configuration
        )
    }
}
