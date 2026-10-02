import Combine
import Foundation

private struct CachedEventList: Codable {
    let events: [PickPicEvent]
    let savedAt: Date
}

@MainActor
final class EventListViewModel:
    ObservableObject
{
    @Published private(set)
    var events: [PickPicEvent] = []

    @Published private(set)
    var statisticsByEventID:
    [String: EventPhotoStatistics] = [:]

    @Published private(set)
    var statisticsFailedEventIDs:
    Set<String> = []

    @Published private(set)
    var isLoading = false

    @Published private(set)
    var isLoadingStatistics = false

    @Published private(set)
    var errorMessage: String?

    /*
     * Whose events this is showing. Every account has its own cache file
     * (AccountScope.eventCacheFilename), so switching accounts swaps the
     * whole list -- offline-created events included -- instead of carrying
     * one account's events into another's. An unknown account (a credential
     * from before accounts were recorded, not yet refreshed) reads and
     * writes the pre-#376 unscoped file, which is what every earlier build
     * showed in that position.
     */
    private enum Scope: Equatable {
        case signedOut
        case account(String?)
    }

    private let fileManager: FileManager
    private var scope = Scope.signedOut
    private var cachedAt: Date?
    private var hasCachedSnapshot = false

    /*
     * Bumped on every scope change. Anything that awaits the network
     * compares it afterwards, so a response for the account that was just
     * switched away from is dropped rather than landing in the new one's
     * list and cache.
     */
    private var scopeGeneration = 0

    init(
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
    }

    private var cacheURL: URL? {
        guard case let .account(accountID) = scope else {
            return nil
        }

        return Self.cacheURL(for: accountID)
    }

    private static func cacheURL(
        for accountID: String?
    ) -> URL {
        AppStorageService.rootURL
            .appendingPathComponent(
                AccountScope.eventCacheFilename(
                    for: accountID
                ),
                isDirectory: false
            )
    }

    /*
     * Called whenever the signed-in account may have changed. Signed out
     * clears what is on screen but leaves every account's cache file in
     * place, so signing back in to the same account shows its list --
     * offline-created events and all -- straight away.
     */
    func activate(
        accountID: String?,
        isSignedIn: Bool
    ) {
        let newScope: Scope =
            isSignedIn
            ? .account(accountID)
            : .signedOut

        guard newScope != scope else {
            return
        }

        scope = newScope
        scopeGeneration += 1

        events = []
        statisticsByEventID = [:]
        statisticsFailedEventIDs = []
        errorMessage = nil
        cachedAt = nil
        hasCachedSnapshot = false

        /*
         * A load still running belongs to the old scope and will be
         * discarded when it returns; leaving this set would make the new
         * scope's first load bail out as a duplicate.
         */
        isLoading = false
        isLoadingStatistics = false

        restoreCachedEvents()
    }

    /*
     * Hands the pre-#376 unscoped cache to the first account this iPad
     * identifies -- see APIConfigurationStore.onAccountIdentified for why
     * that is the account it belongs to. Replaces any file the account
     * already has: the unscoped file is only ever written while the
     * signed-in account is unknown, so if one exists it is the newer
     * snapshot of this same account.
     */
    static func adoptLegacyCache(
        into accountID: String,
        fileManager: FileManager = .default
    ) {
        let legacyURL = cacheURL(for: nil)

        guard fileManager.fileExists(
            atPath: legacyURL.path
        ) else {
            return
        }

        let scopedURL = cacheURL(for: accountID)

        do {
            if fileManager.fileExists(
                atPath: scopedURL.path
            ) {
                try fileManager.removeItem(
                    at: scopedURL
                )
            }

            try fileManager.moveItem(
                at: legacyURL,
                to: scopedURL
            )
        } catch {
            print(
                "Unable to adopt the legacy event cache:",
                error
            )
        }
    }

    func load(
        using configuration:
        APIConfigurationStore
    ) async {
        guard !isLoading else {
            return
        }

        guard configuration.isConfigured else {
            if hasCachedSnapshot {
                errorMessage = cachedEventsMessage(
                    detail:
                        "Sign in to PickPic to refresh this list."
                )
            } else {
                events = []
                statisticsByEventID = [:]
                statisticsFailedEventIDs = []

                errorMessage =
                    """
                    Sign in to PickPic to load \
                    your events.
                    """
            }

            return
        }

        isLoading = true
        errorMessage = nil

        let generation = scopeGeneration

        do {
            let client =
            try configuration.makeClient()

            let loadedEvents =
            try await client.fetchEvents()

            guard generation == scopeGeneration else {
                return
            }

            let loadedEventIDs =
            Set(loadedEvents.map(\.id))

            /*
             * Events created offline are not on the server yet, so a
             * refresh would drop them from the list and strand the work
             * queued against them. They survive here until the server
             * reports the same id back, which is how a pending event
             * stops being pending.
             */
            let unsyncedEvents =
            events.filter { event in
                event.needsRemoteCreation
                    && !loadedEventIDs.contains(event.id)
            }

            events = unsyncedEvents + loadedEvents

            let validEventIDs =
            loadedEventIDs.union(
                unsyncedEvents.map(\.id)
            )

            statisticsByEventID =
            statisticsByEventID.filter {
                eventID, _ in
                validEventIDs.contains(eventID)
            }

            statisticsFailedEventIDs =
            statisticsFailedEventIDs
                .intersection(validEventIDs)

            persistCachedEvents()

            isLoading = false

            await refreshStatistics(
                using: configuration
            )
        } catch {
            guard generation == scopeGeneration else {
                return
            }

            isLoading = false

            if hasCachedSnapshot {
                errorMessage = cachedEventsMessage(
                    detail: error.localizedDescription
                )
            } else {
                errorMessage =
                error.localizedDescription
            }
        }
    }

    func refreshStatistics(
        using configuration:
        APIConfigurationStore
    ) async {
        guard
            configuration.isConfigured,
            !isLoadingStatistics,
            !events.isEmpty
        else {
            return
        }

        isLoadingStatistics = true

        let generation = scopeGeneration

        defer {
            // activate() has already reset it for the new scope.
            if generation == scopeGeneration {
                isLoadingStatistics = false
            }
        }

        let client: APIClient

        do {
            client =
            try configuration.makeClient()
        } catch {
            return
        }

        var refreshedStatistics =
        statisticsByEventID

        var failedEventIDs:
        Set<String> = []

        for event in events {
            guard
                !Task.isCancelled,
                generation == scopeGeneration
            else {
                return
            }

            do {
                let photos =
                try await client.fetchEventPhotos(
                    eventID: event.id
                )

                refreshedStatistics[event.id] =
                EventPhotoStatistics(
                    photos: photos
                )
            } catch {
                failedEventIDs.insert(event.id)
            }
        }

        let currentEventIDs =
        Set(events.map(\.id))

        statisticsByEventID =
        refreshedStatistics.filter {
            eventID, _ in
            currentEventIDs.contains(eventID)
        }

        statisticsFailedEventIDs =
        failedEventIDs
    }

    /*
     * The id is chosen here rather than by the server, so an event can
     * be named and worked on before the network is reachable and still
     * keep that identity once it syncs. Creation is idempotent server
     * side, so retrying with the same id converges instead of leaving a
     * duplicate.
     *
     * It is returned so the caller can select the event it just made,
     * on both paths — the offline one names an event that is every bit
     * as usable as a synced one.
     */
    func createEvent(
        title: String,
        using configuration:
        APIConfigurationStore
    ) async throws -> String {
        let eventID = UUID().uuidString.lowercased()
        let generation = scopeGeneration

        do {
            let client =
            try configuration.makeClient()

            let createdEvent =
            try await client.createEvent(
                title: title,
                id: eventID
            )

            /*
             * Created under the account that was signed in when the
             * request went out, so it belongs in that account's list --
             * which is no longer this one if the iPad switched meanwhile.
             * It is already on the server and appears when that account
             * signs back in.
             */
            guard generation == scopeGeneration else {
                return eventID
            }

            insert(createdEvent)
        } catch {
            guard generation == scopeGeneration else {
                throw error
            }

            /*
             * Only an unreachable server justifies working offline. A
             * request the server actively rejected, such as an invalid
             * title, is a real failure and must surface.
             */
            guard isOfflineError(error) else {
                throw error
            }

            let now = Date()

            insert(
                PickPicEvent(
                    id: eventID,
                    title: title,
                    shareToken: "",
                    status: .draft,
                    createdAt: now,
                    updatedAt: now,
                    isPendingCreation: true
                )
            )
        }

        return eventID
    }

    /*
     * Drops the local-only marker once an event is known to exist on the
     * server, so the list stops saying otherwise without waiting for the
     * next refresh. The event itself is already correct either way.
     */
    func markEventsCreatedRemotely(
        _ eventIDs: Set<String>
    ) {
        guard !eventIDs.isEmpty else {
            return
        }

        var didChange = false

        events = events.map { event in
            guard
                event.needsRemoteCreation,
                eventIDs.contains(event.id)
            else {
                return event
            }

            didChange = true

            var updated = event
            updated.isPendingCreation = false

            return updated
        }

        guard didChange else {
            return
        }

        persistCachedEvents()
    }

    private func insert(
        _ event: PickPicEvent
    ) {
        events.removeAll { existing in
            existing.id == event.id
        }

        events.insert(
            event,
            at: 0
        )

        statisticsByEventID[event.id] = .empty

        statisticsFailedEventIDs.remove(event.id)

        errorMessage = nil
        persistCachedEvents()
    }

    /*
     * Treats an unconfigured client and a transport failure as offline.
     * APIClientError.server means the request reached PickPic and was
     * refused, which is not something waiting will fix.
     */
    private func isOfflineError(
        _ error: Error
    ) -> Bool {
        if error is URLError {
            return true
        }

        if case APIClientError.server = error {
            return false
        }

        return true
    }

    /*
     * One event's counts, for a change made outside this view model -- a
     * RAW delivered by the automatic sweep. refreshStatistics would refetch
     * every event to update one. A failure keeps the old counts: the next
     * full refresh corrects them, and this is not worth an error state.
     */
    func refreshStatistics(
        for eventID: String,
        using configuration:
        APIConfigurationStore
    ) async {
        guard
            configuration.isConfigured,
            let client =
                try? configuration.makeClient(),
            let photos =
                try? await client.fetchEventPhotos(
                    eventID: eventID
                )
        else {
            return
        }

        replaceStatistics(
            EventPhotoStatistics(
                photos: photos
            ),
            for: eventID
        )
    }

    func replaceStatistics(
        _ statistics: EventPhotoStatistics,
        for eventID: String
    ) {
        guard events.contains(
            where: { event in
                event.id == eventID
            }
        ) else {
            return
        }

        statisticsByEventID[eventID] =
        statistics

        statisticsFailedEventIDs.remove(
            eventID
        )
    }

    func replaceEvent(
        _ updatedEvent: PickPicEvent
    ) {
        guard
            let index = events.firstIndex(
                where: { event in
                    event.id == updatedEvent.id
                }
            )
        else {
            return
        }

        events[index] = updatedEvent
        persistCachedEvents()
    }

    func removeEvent(
        eventID: String
    ) {
        events.removeAll { event in
            event.id == eventID
        }

        statisticsByEventID[eventID] = nil
        statisticsFailedEventIDs.remove(
            eventID
        )

        persistCachedEvents()
    }

    private func restoreCachedEvents() {
        guard
            let cacheURL,
            fileManager.fileExists(
                atPath: cacheURL.path
            )
        else {
            return
        }

        do {
            let data = try Data(
                contentsOf: cacheURL
            )

            let snapshot = try JSONDecoder()
                .decode(
                    CachedEventList.self,
                    from: data
                )

            events = snapshot.events
            cachedAt = snapshot.savedAt
            hasCachedSnapshot = true
        } catch {
            print(
                "Unable to restore cached events:",
                error
            )
        }
    }

    private func persistCachedEvents() {
        guard let cacheURL else {
            return
        }

        let savedAt = Date()
        let snapshot = CachedEventList(
            events: events,
            savedAt: savedAt
        )

        do {
            try fileManager.createDirectory(
                at: AppStorageService.rootURL,
                withIntermediateDirectories: true
            )

            let data = try JSONEncoder()
                .encode(snapshot)

            try data.write(
                to: cacheURL,
                options: .atomic
            )

            cachedAt = savedAt
            hasCachedSnapshot = true
        } catch {
            print(
                "Unable to persist cached events:",
                error
            )
        }
    }

    private func cachedEventsMessage(
        detail: String
    ) -> String {
        let savedDescription: String

        if let cachedAt {
            savedDescription = cachedAt.formatted(
                date: .abbreviated,
                time: .shortened
            )
        } else {
            savedDescription = "an earlier session"
        }

        return """
        Showing saved events from \(savedDescription). \(detail)
        """
    }
}
