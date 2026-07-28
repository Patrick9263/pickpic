import Combine
import Foundation

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

    func load(
        using configuration:
        APIConfigurationStore
    ) async {
        guard !isLoading else {
            return
        }

        guard configuration.isConfigured else {
            events = []
            statisticsByEventID = [:]
            statisticsFailedEventIDs = []

            errorMessage =
                """
                Open Connection Settings to connect \
                to PickPic.
                """

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

            isLoading = false

            await refreshStatistics(
                using: configuration
            )
        } catch {
            isLoading = false
            errorMessage =
            error.localizedDescription
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
    }
}
