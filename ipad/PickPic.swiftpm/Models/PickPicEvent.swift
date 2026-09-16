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
     * A pending event has no share token until the server assigns one.
     */
    var isPublishable: Bool {
        !needsRemoteCreation
            && !shareToken.isEmpty
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
