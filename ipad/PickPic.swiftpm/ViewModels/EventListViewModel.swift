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

    private let fileManager: FileManager
    private let cacheURL: URL
    private var cachedAt: Date?
    private var hasCachedSnapshot = false

    init(
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        cacheURL = AppStorageService.rootURL
            .appendingPathComponent(
                "events-cache.json",
                isDirectory: false
            )

        restoreCachedEvents()
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
                        "Open Connection Settings to refresh from PickPic."
                )
            } else {
                events = []
                statisticsByEventID = [:]
                statisticsFailedEventIDs = []

                errorMessage =
                    """
                    Open Connection Settings to connect \
                    to PickPic.
                    """
            }

            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let client =
            try configuration.makeClient()

            let loadedEvents =
            try await client.fetchEvents()

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

        defer {
            isLoadingStatistics = false
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
            guard !Task.isCancelled else {
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
     */
    func createEvent(
        title: String,
        using configuration:
        APIConfigurationStore
    ) async throws {
        let eventID = UUID().uuidString.lowercased()

        do {
            let client =
            try configuration.makeClient()

            let createdEvent =
            try await client.createEvent(
                title: title,
                id: eventID
            )

            insert(createdEvent)
        } catch {
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
        guard fileManager.fileExists(
            atPath: cacheURL.path
        ) else {
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
