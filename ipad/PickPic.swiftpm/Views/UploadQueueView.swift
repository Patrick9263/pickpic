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
                    job: job
                ) {
                    Task {
                        await uploadQueue.prepare(
                            jobID: job.id
                        )
                    }
                }
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
                }
            )
        else {
            deleteErrorMessage =
                """
                Wait for folder preparation to finish \
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
                "To Edit and Edited folders are ready",
                systemImage: "checkmark.circle"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            
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
            
        case .converting,
                .uploading,
                .completed:
            EmptyView()
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
