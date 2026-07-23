import SwiftUI
import UIKit

struct PublishGalleryView: View {
    @State private var event: PickPicEvent
    
    let onEventUpdated:
    (PickPicEvent) -> Void
    
    @EnvironmentObject private var configuration:
    APIConfigurationStore
    
    @EnvironmentObject private var uploadQueue:
    UploadQueueStore
    
    @StateObject private var viewModel =
    PublishGalleryViewModel()
    
    @State private var showingPublishConfirmation = false
    @State private var showingCleanupConfirmation = false
    @State private var cleanupErrorMessage:String?
    @State private var showingShareSheet = false
    
    init(
        event: PickPicEvent,
        onEventUpdated:
        @escaping (PickPicEvent) -> Void
    ) {
        _event = State(
            initialValue: event
        )
        
        self.onEventUpdated =
        onEventUpdated
    }
    
    private var galleryURL: URL {
        PickPicEnvironment.galleryURL(
            shareToken: event.shareToken
        )
    }
    
    private var completedJobCount: Int {
        uploadQueue.completedJobCount(
            for: event.id
        )
    }
    
    private var galleryIsViewable: Bool {
        event.status == .ready
        || event.status == .completed
    }
    
    private var canPublish: Bool {
        switch event.status {
        case .draft,
                .uploading,
                .editing:
            return true
            
        case .ready,
                .completed,
                .archived:
            return false
        }
    }
    
    var body: some View {
        Form {
            Section("Gallery Status") {
                LabeledContent {
                    Label(
                        event.status.title,
                        systemImage:
                            event.status.systemImage
                    )
                } label: {
                    Text("Status")
                }
                
                photoCountContent
                
                statusDescription
            }
            
            galleryActions
            
            if galleryIsViewable {
                shareSection
            }
            
            if completedJobCount > 0 {
                cleanupSection
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
            
            if let cleanupErrorMessage {
                Section {
                    Label(
                        cleanupErrorMessage,
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Publish & Share")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: event.id) {
            await viewModel.load(
                eventID: event.id,
                using: configuration
            )
        }
        .refreshable {
            await viewModel.load(
                eventID: event.id,
                using: configuration
            )
        }
        .sheet(
            isPresented: $showingShareSheet
        ) {
            ActivityView(
                activityItems: [galleryURL]
            )
            .presentationDetents([
                .medium,
                .large
            ])
        }
    }
    
    @ViewBuilder
    private var photoCountContent: some View {
        if let photoCount =
            viewModel.serverPhotoCount {
            LabeledContent(
                "Server photos",
                value: "\(photoCount)"
            )
        } else if viewModel.isLoading {
            HStack {
                Text("Server photos")
                
                Spacer()
                
                ProgressView()
            }
        } else {
            LabeledContent(
                "Server photos",
                value: "Unknown"
            )
        }
    }
    
    @ViewBuilder
    private var statusDescription: some View {
        switch event.status {
        case .draft,
                .uploading,
                .editing:
            Text(
                """
                The gallery is private and cannot yet be \
                opened through its share link.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            
        case .ready:
            Text(
                """
                The gallery is live and accepts photo \
                requests and comments.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            
        case .completed:
            Text(
                """
                The gallery remains viewable, but edit \
                requests and comments are closed.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            
        case .archived:
            Text(
                "This gallery is archived."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private var galleryActions: some View {
        if canPublish {
            Section {
                Button {
                    showingPublishConfirmation = true
                } label: {
                    if viewModel.isPublishing {
                        HStack(spacing: 10) {
                            ProgressView()
                            
                            Text("Publishing…")
                        }
                    } else {
                        Label(
                            "Publish Gallery",
                            systemImage:
                                "globe.badge.chevron.backward"
                        )
                    }
                }
                .disabled(
                    viewModel.isPublishing
                    || viewModel.isLoading
                    || viewModel.serverPhotoCount == 0
                )
                .confirmationDialog(
                    "Publish Gallery?",
                    isPresented: $showingPublishConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Publish Gallery") {
                        publishGallery()
                    }
                    
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        """
                        This will make the gallery available \
                        to anyone with its share link.
                        """
                    )
                }
            } footer: {
                if viewModel.serverPhotoCount == 0 {
                    Text(
                        """
                        Upload at least one photo before \
                        publishing.
                        """
                    )
                } else {
                    Text(
                        """
                        Publishing changes the event status \
                        to Ready.
                        """
                    )
                }
            }
        } else if event.status == .ready {
            Section {
                Label(
                    "Gallery is live",
                    systemImage:
                        "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            }
        }
    }
    
    private var shareSection: some View {
        Section("Share Link") {
            Text(galleryURL.absoluteString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            
            Link(destination: galleryURL) {
                HStack {
                    Label(
                        "Open Gallery",
                        systemImage: "safari"
                    )
                    
                    Spacer()
                    
                    Image(
                        systemName: "arrow.up.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            
            Button {
                showingShareSheet = true
            } label: {
                HStack {
                    Label(
                        "Share Gallery Link",
                        systemImage:
                            "square.and.arrow.up"
                    )
                    
                    Spacer()
                }
            }
            .buttonStyle(.borderless)
        }
    }
    
    private var cleanupSection: some View {
        Section {
            LabeledContent(
                "Completed jobs",
                value: "\(completedJobCount)"
            )
            
            Button(role: .destructive) {
                cleanupErrorMessage = nil
                showingCleanupConfirmation = true
            } label: {
                Label(
                    "Remove Completed Uploads",
                    systemImage: "trash"
                )
            }
            .confirmationDialog(
                "Remove Completed Uploads?",
                isPresented: $showingCleanupConfirmation,
                titleVisibility: .visible
            ) {
                Button(
                    "Remove Completed Uploads",
                    role: .destructive
                ) {
                    removeCompletedUploads()
                }
                
                Button(
                    "Cancel",
                    role: .cancel
                ) {}
            } message: {
                Text(
                """
                This removes completed queue records and \
                temporary app files. Original photos, \
                To Edit, and Edited are not changed.
                """
                )
            }
        } header: {
            Text("Completed Uploads")
        } footer: {
            Text(
            """
            This removes only local queue records and \
            temporary converted files.
            """
            )
        }
    }
    
    private func publishGallery() {
        Task {
            guard
                let updatedEvent =
                    await viewModel.publish(
                        event: event,
                        using: configuration
                    )
            else {
                return
            }
            
            event = updatedEvent
            onEventUpdated(updatedEvent)
        }
    }
    
    private func removeCompletedUploads() {
        do {
            try uploadQueue
                .removeCompletedJobs(
                    for: event.id
                )
            
            cleanupErrorMessage = nil
        } catch {
            cleanupErrorMessage =
            error.localizedDescription
        }
    }
}

private struct ActivityView:
    UIViewControllerRepresentable
{
    let activityItems: [Any]
    
    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }
    
    func updateUIViewController(
        _ uiViewController:
        UIActivityViewController,
        context: Context
    ) {
        // No updates are required.
    }
}
