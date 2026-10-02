import Combine
import Foundation

/*
 * The two lists RawRequestsView renders, kept as pure functions over the
 * fetched photo list so they're testable without a view model or a
 * network (#373).
 */
enum RawRequestList {
    /*
     * Same photos RawRequestSyncService.sync will act on next activation —
     * this reads the already-fetched list rather than asking the server
     * again, so the count on screen matches what the background sweep will
     * see (#217). Filename order, which is also the order the sweep works
     * through them.
     */
    static func pending(
        in photos: [ServerPhotoRecord]
    ) -> [ServerPhotoRecord] {
        photos
            .filter { photo in
                photo.needsRawUpload
            }
            .sorted { first, second in
                first.originalFilename
                    .localizedStandardCompare(
                        second.originalFilename
                    )
                == .orderedAscending
            }
    }

    /*
     * A RAW only ever reaches R2 because a viewer asked for it, so any
     * photo carrying one has been delivered — including one a newer
     * visitor has since re-requested, which needsRawUpload deliberately
     * excludes from pending. Newest first: uploadedAt is a fixed-format
     * ISO 8601 string from the server, so string order is time order.
     */
    static func delivered(
        in photos: [ServerPhotoRecord]
    ) -> [ServerPhotoRecord] {
        photos
            .filter { photo in
                photo.rawPhoto != nil
            }
            .sorted { first, second in
                (first.rawPhoto?.uploadedAt ?? "")
                > (second.rawPhoto?.uploadedAt ?? "")
            }
    }
}

@MainActor
final class RawRequestsViewModel:
    ObservableObject
{
    @Published private(set)
    var photos: [ServerPhotoRecord] = []

    @Published private(set)
    var isLoading = false

    @Published private(set)
    var errorMessage: String?

    var pendingPhotos: [ServerPhotoRecord] {
        RawRequestList.pending(in: photos)
    }

    var deliveredPhotos: [ServerPhotoRecord] {
        RawRequestList.delivered(in: photos)
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
}
