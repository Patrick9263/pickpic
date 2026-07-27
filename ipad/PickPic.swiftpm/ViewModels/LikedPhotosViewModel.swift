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

    @Published private(set)
    var lastCheckedAt: Date?

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
        guard !isLoading, !isSyncing else {
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

            lastCheckedAt = Date()
        } catch {
            errorMessage =
            error.localizedDescription
        }
    }

    func refreshAndSync(
        eventID: String,
        reference: EventFolderReference?,
        using configuration:
        APIConfigurationStore
    ) async {
        guard let reference else {
            await load(
                eventID: eventID,
                using: configuration
            )

            return
        }

        await sync(
            eventID: eventID,
            reference: reference,
            using: configuration
        )
    }

    func sync(
        eventID: String,
        reference: EventFolderReference,
        using configuration:
        APIConfigurationStore
    ) async {
        guard !isLoading, !isSyncing else {
            return
        }

        let shouldShowInitialLoader =
        photos.isEmpty

        if shouldShowInitialLoader {
            isLoading = true
        }

        isSyncing = true
        errorMessage = nil
        markedEditingCount = 0
        workflowUpdateFailures = []

        defer {
            isLoading = false
            isSyncing = false
        }

        do {
            let client =
            try configuration.makeClient()

            guard let result =
                try await RequestedPhotoSyncService
                    .sync(
                        eventID: eventID,
                        reference: reference,
                        using: client
                    )
            else {
                photos = try await client
                    .fetchEventPhotos(
                        eventID: eventID
                    )

                lastCheckedAt = Date()
                return
            }

            photos = result.photos
            syncResult = result.fileResult
            markedEditingCount =
            result.markedEditingCount
            workflowUpdateFailures =
            result.workflowUpdateFailures
            lastCheckedAt = Date()
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
