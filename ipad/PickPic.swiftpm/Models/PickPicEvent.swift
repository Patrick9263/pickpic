import Foundation

struct PickPicEvent: Identifiable, Hashable, Codable {
    enum Status: String, Codable, CaseIterable {
        case draft
        case ready
        case completed
        case archived

        var title: String {
            switch self {
            case .draft:
                return "Draft"

            case .ready:
                return "Open"

            case .completed:
                return "Closed"

            case .archived:
                return "Archived"
            }
        }

        var systemImage: String {
            switch self {
            case .draft:
                return "pencil"

            case .ready:
                return "checkmark.circle"

            case .completed:
                return "checkmark.seal"

            case .archived:
                return "archivebox"
            }
        }

        /*
         * .ready still takes new hearts; .completed stops taking new ones
         * (worker's requireOpenGallery returns 409) but existing hearts on
         * it still need their RAWs synced and delivered. .draft never had a
         * published gallery to heart from, and .archived is the
         * photographer's own signal that delivery is done. Used by the
         * requested-photo sweep to skip events with nothing left to do
         * (#235) instead of re-fetching every event the device has ever
         * pointed at.
         */
        var mayHavePendingGalleryWork: Bool {
            self == .ready || self == .completed
        }
    }
    
    let id: String
    let title: String
    let shareToken: String
    let status: Status
    let createdAt: Date
    let updatedAt: Date

    /*
     * Set on an event created while offline, which exists only on this
     * device until its first successful sync.
     *
     * Optional so that events decoded from the server, and events cached
     * before this existed, both read as nil and are treated as created.
     * The id is chosen locally and never changes, so nothing keyed by it
     * has to be rewritten once the server knows about the event.
     */
    var isPendingCreation: Bool? = nil

    var needsRemoteCreation: Bool {
        isPendingCreation == true
    }

    /*
     * Both optional for the same reason as isPendingCreation above: an
     * event still only on this device, or cached from before this field
     * existed, decodes with neither present rather than failing outright.
     * A server response always sends both, so nil only ever means "not
     * yet known" -- treated as enabled/no-requests so a brand-new local
     * event doesn't show a stale "off" toggle before its first sync.
     */
    var rawRequestsEnabled: Bool? = nil
    var hasRawRequests: Bool? = nil

    /*
     * A pending event has no share token until the server assigns one.
     */
    var isPublishable: Bool {
        !needsRemoteCreation
            && !shareToken.isEmpty
    }

    /*
     * Whether a failed server delete still leaves the event deleted, so
     * the local copy -- list entry, queued jobs, folder reference -- should
     * go too.
     *
     * A 404 always does: the server not having the event is exactly what
     * deleting asks for. Without this, an event created offline and never
     * synced could not be deleted at all, because the server has never
     * heard of it.
     *
     * Being offline does too, but only for an event still marked as never
     * synced; a synced event's server copy cannot be confirmed gone, so
     * that delete has to wait for a connection. The marker can lag a sync
     * by moments (ContentView clears it once a job's upload starts), so a
     * server copy can occasionally survive this. That copy reappears on the
     * next refresh, where it can be deleted again -- recoverable, unlike
     * leaving the photographer unable to delete the event.
     */
    func isDeleted(
        despite error: Error
    ) -> Bool {
        if case APIClientError.server(404, _) = error {
            return true
        }

        return needsRemoteCreation && error is URLError
    }
}

extension PickPicEvent {
    static let previewEvents: [PickPicEvent] = [
        PickPicEvent(
            id: "preview-boston",
            title: "Boston Photo Walk",
            shareToken: "preview-boston-token",
            status: .ready,
            createdAt: .now.addingTimeInterval(-172_800),
            updatedAt: .now.addingTimeInterval(-3_600)
        ),
        PickPicEvent(
            id: "preview-test",
            title: "PickPic Test Event",
            shareToken: "preview-test-token",
            status: .draft,
            createdAt: .now.addingTimeInterval(-86_400),
            updatedAt: .now.addingTimeInterval(-7_200)
        )
    ]
}
