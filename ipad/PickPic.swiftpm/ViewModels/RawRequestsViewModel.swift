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

/*
 * What RawRequestsView does with a list it has just loaded. Delivery used
 * to start only from App.swift's sweep, every 30 seconds, so a request the
 * screen was already showing sat on "Waiting" until the next pass came
 * round; starting it from the load closes that gap without shortening the
 * sweep's interval.
 */
enum RawRequestLoadFollowUp: Equatable {
    case none
    case startDelivery

    /*
     * The list may have been read from the server before a delivery that
     * landed while the fetch was in flight, so it can still show that
     * photo as pending -- and handing it to sync() would send the same RAW
     * a second time. The delivery's own reload, which would have corrected
     * it, was dropped by load()'s isLoading guard, so this asks for another.
     */
    case reload

    static func after(
        loading photos: [ServerPhotoRecord],
        eventStatus: PickPicEvent.Status,
        deliveryBeforeFetch: RawDeliveryProgress.Delivery?,
        deliveryAfterFetch: RawDeliveryProgress.Delivery?
    ) -> RawRequestLoadFollowUp {
        guard deliveryAfterFetch == deliveryBeforeFetch else {
            return .reload
        }

        /*
         * The same eligibility the sweep applies (#235), so opening the
         * screen never sends originals for an event the sweep would leave
         * alone.
         */
        guard
            eventStatus.mayHavePendingGalleryWork,
            !RawRequestList.pending(in: photos).isEmpty
        else {
            return .none
        }

        return .startDelivery
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

    /*
     * Returns the list it fetched, or nil when it fetched nothing -- either
     * a load was already running or the request failed.
     */
    @discardableResult
    func load(
        eventID: String,
        using configuration:
        APIConfigurationStore
    ) async -> [ServerPhotoRecord]? {
        guard !isLoading else {
            return nil
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

            return photos
        } catch {
            errorMessage =
            error.localizedDescription

            return nil
        }
    }
}
