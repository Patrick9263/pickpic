import Combine
import Foundation

@MainActor
final class LikedPhotosViewModel:
    ObservableObject
{
    @Published private(set)
    var photos: [ServerPhotoRecord] = []
    
    @Published private(set)
    var isLoading = false
    
    @Published private(set)
    var isSyncing = false
    
    @Published private(set)
    var errorMessage: String?
    
    @Published private(set)
    var syncResult: ToEditSyncResult?
    
    @Published private(set)
    var markedEditingCount = 0
    
    @Published private(set)
    var workflowUpdateFailures: [String] = []
    
    var likedPhotos: [ServerPhotoRecord] {
        photos
            .filter { photo in
                photo.heartCount > 0
            }
            .sorted { first, second in
                first.originalFilename
                    .localizedStandardCompare(
                        second.originalFilename
                    )
                == .orderedAscending
            }
    }
    
    var editingLikedPhotoCount: Int {
        likedPhotos.filter { photo in
            photo.workflowStatus == .editing
        }
        .count
    }
    
    func load(
        eventID: String,
        using configuration:
        APIConfigurationStore
    ) async {
        guard !isLoading else {
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        defer {
            isLoading = false
        }
        
        do {
            let client =
            try configuration.makeClient()
            
            photos = try await client
                .fetchEventPhotos(
                    eventID: eventID
                )
        } catch {
            errorMessage =
            error.localizedDescription
        }
    }
    
    func sync(
        eventID: String,
        reference: EventFolderReference,
        using configuration:
        APIConfigurationStore
    ) async {
        guard !isSyncing else {
            return
        }
        
        isSyncing = true
        errorMessage = nil
        markedEditingCount = 0
        workflowUpdateFailures = []
        
        defer {
            isSyncing = false
        }
        
        do {
            let client =
            try configuration.makeClient()
            
            let currentPhotos =
            try await client.fetchEventPhotos(
                eventID: eventID
            )
            
            photos = currentPhotos
            
            let fileSyncResult =
            try await Task.detached(
                priority: .userInitiated
            ) {
                try ToEditSyncService.sync(
                    reference: reference,
                    photos: currentPhotos
                )
            }
            .value
            
            syncResult = fileSyncResult
            
            let photosToMarkEditing =
            currentPhotos.filter { photo in
                photo.heartCount > 0
                && fileSyncResult
                    .syncedFilenames
                    .contains(
                        photo.originalFilename
                    )
                && photo.workflowStatus
                != .editing
            }
            
            for photo in photosToMarkEditing {
                do {
                    _ = try await client
                        .setPhotoWorkflowStatus(
                            .editing,
                            for: photo.id
                        )
                    
                    markedEditingCount += 1
                } catch {
                    workflowUpdateFailures.append(
                        photo.originalFilename
                    )
                }
            }
            
            photos = try await client
                .fetchEventPhotos(
                    eventID: eventID
                )
        } catch {
            errorMessage =
            error.localizedDescription
        }
    }
    
    func showError(
        _ error: Error
    ) {
        errorMessage =
        error.localizedDescription
    }
}
