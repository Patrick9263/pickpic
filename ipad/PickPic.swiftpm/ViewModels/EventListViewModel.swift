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

            events = loadedEvents

            let validEventIDs =
            Set(loadedEvents.map(\.id))

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

    func createEvent(
        title: String,
        using configuration:
        APIConfigurationStore
    ) async throws {
        let client =
        try configuration.makeClient()

        let createdEvent =
        try await client.createEvent(
            title: title
        )

        events.removeAll { event in
            event.id == createdEvent.id
        }

        events.insert(
            createdEvent,
            at: 0
        )

        statisticsByEventID[
            createdEvent.id
        ] = .empty

        statisticsFailedEventIDs.remove(
            createdEvent.id
        )

        errorMessage = nil
        persistCachedEvents()
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
