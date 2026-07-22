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
                UploadJobRow(job: job)
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
        let jobIDs = Set(
            offsets.map { index in
                eventJobs[index].id
            }
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
        }
        .padding(.vertical, 5)
        .task(id: job.id) {
            folderIsAccessible =
            FolderBookmarkService
                .canAccessFolder(
                    using:
                        job.folderBookmarkData
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
