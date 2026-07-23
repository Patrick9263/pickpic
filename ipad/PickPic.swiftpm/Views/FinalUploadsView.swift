import SwiftUI
import UniformTypeIdentifiers

struct FinalUploadsView: View {
    let event: PickPicEvent
    
    @EnvironmentObject private var configuration:
    APIConfigurationStore
    
    @EnvironmentObject private var eventFolders:
    EventFolderStore
    
    @StateObject private var viewModel =
    FinalUploadsViewModel()
    
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
            
            if let scanResult =
                viewModel.scanResult {
                summarySection(scanResult)
                readyFinalsSection(scanResult)
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
            
            if let uploadedCount =
                viewModel.lastUploadedCount,
               uploadedCount > 0
            {
                Section("Last Upload") {
                    Label(
                        """
                        \(uploadedCount) final \
                        \(uploadedCount == 1
                            ? "photo"
                            : "photos") uploaded
                        """,
                        systemImage:
                            "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
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
        }
        .safeAreaInset(edge: .bottom) {
            if
                let folderReference,
                let scanResult =
                    viewModel.scanResult,
                !scanResult.candidates.isEmpty
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
        VStack(spacing: 8) {
            if viewModel.isUploading {
                ProgressView(
                    value:
                        Double(
                            viewModel.uploadedCount
                        ),
                    total:
                        Double(
                            max(
                                scanResult
                                    .candidates
                                    .count,
                                1
                            )
                        )
                )
                
                Text(
                    """
                    \(viewModel.uploadedCount) of \
                    \(scanResult.candidates.count) uploaded
                    """
                )
                .font(.subheadline)
                
                if let filename =
                    viewModel.currentFilename {
                    Text(filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Button {
                Task {
                    await viewModel.uploadAll(
                        eventID: event.id,
                        reference: reference,
                        using: configuration
                    )
                }
            } label: {
                if viewModel.isUploading {
                    HStack(spacing: 10) {
                        ProgressView()
                        
                        Text("Uploading Finals…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
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
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isUploading)
        }
        .padding()
        .background(.regularMaterial)
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
