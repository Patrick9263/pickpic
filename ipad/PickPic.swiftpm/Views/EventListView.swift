import SwiftUI

struct EventListView: View {
    let events: [PickPicEvent]

    let statisticsByEventID:
    [String: EventPhotoStatistics]

    let statisticsFailedEventIDs:
    Set<String>

    let isLoading: Bool
    let isLoadingStatistics: Bool
    let errorMessage: String?

    let onRefresh: () async -> Void
    let onCreateEvent:
    (String) async throws -> Void

    let onEventUpdated:
    (PickPicEvent) -> Void

    let onEventStatisticsUpdated:
    (String, EventPhotoStatistics) -> Void

    let onEventDeleted:
    (String) -> Void

    @EnvironmentObject private var uploadQueue:
    UploadQueueStore

    @State private var showingCreateEvent = false
    @State private var searchText = ""
    @State private var selectedFilter:
    EventDashboardFilter = .all
    @State private var selectedSort:
    EventDashboardSort = .updated

    private var visibleEvents: [PickPicEvent] {
        events
            .filter { event in
                searchMatches(event)
                && selectedFilter.matches(
                    event,
                    unfinishedJobCount:
                        unfinishedJobCount(
                            for: event.id
                        )
                )
            }
            .sorted { first, second in
                selectedSort.isOrderedBefore(
                    first,
                    second,
                    statisticsByEventID:
                        statisticsByEventID
                )
            }
    }

    private var visibleStatistics:
    EventPhotoStatistics
    {
        visibleEvents.reduce(.empty) {
            result,
            event in

            guard let statistics =
                statisticsByEventID[event.id]
            else {
                return result
            }

            return EventPhotoStatistics(
                uploadedProofCount:
                    result.uploadedProofCount
                    + statistics.uploadedProofCount,
                likedPhotoCount:
                    result.likedPhotoCount
                    + statistics.likedPhotoCount,
                totalHeartCount:
                    result.totalHeartCount
                    + statistics.totalHeartCount,
                editingPhotoCount:
                    result.editingPhotoCount
                    + statistics.editingPhotoCount,
                uploadedFinalCount:
                    result.uploadedFinalCount
                    + statistics.uploadedFinalCount,
                missingVariantPhotoCount:
                    result.missingVariantPhotoCount
                    + statistics.missingVariantPhotoCount
            )
        }
    }

    private var visibleIncompleteJobCount: Int {
        visibleEvents.reduce(0) { total, event in
            total
            + unfinishedJobCount(
                for: event.id
            )
        }
    }

    private var hasVisibleStatistics: Bool {
        visibleEvents.contains { event in
            statisticsByEventID[event.id] != nil
        }
    }

    private var hasVisibleStatisticsFailure: Bool {
        visibleEvents.contains { event in
            statisticsFailedEventIDs.contains(
                event.id
            )
        }
    }

    var body: some View {
        List {
            if
                let errorMessage,
                !events.isEmpty
            {
                Section {
                    VStack(
                        alignment: .leading,
                        spacing: 10
                    ) {
                        Label(
                            "Unable to Refresh",
                            systemImage:
                                "exclamationmark.triangle"
                        )
                        .font(.headline)

                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button("Try Again") {
                            Task {
                                await onRefresh()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !events.isEmpty {
                Section {
                    EventOverview(
                        eventCount:
                            visibleEvents.count,
                        statistics:
                            visibleStatistics,
                        incompleteJobCount:
                            visibleIncompleteJobCount,
                        showsPlaceholder:
                            !hasVisibleStatistics
                            && isLoadingStatistics
                    )
                } header: {
                    HStack {
                        Text("Overview")

                        Spacer()

                        if isLoadingStatistics {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                } footer: {
                    if hasVisibleStatisticsFailure {
                        Label(
                            "Some event statistics could not be refreshed.",
                            systemImage:
                                "exclamationmark.triangle"
                        )
                    } else {
                        Text(overviewFooterText)
                    }
                }
            }

            if
                visibleEvents.isEmpty,
                !events.isEmpty
            {
                Section {
                    ContentUnavailableView {
                        Label(
                            "No Matching Events",
                            systemImage:
                                "line.3.horizontal.decrease.circle"
                        )
                    } description: {
                        Text(
                            "Try another search or event filter."
                        )
                    } actions: {
                        Button("Show All Events") {
                            searchText = ""
                            selectedFilter = .all
                        }
                    }
                }
            } else {
                ForEach(visibleEvents) { event in
                    NavigationLink(value: event) {
                        let jobs = uploadQueue.jobs(
                            for: event.id
                        )

                        EventRow(
                            event: event,
                            statistics:
                                statisticsByEventID[
                                    event.id
                                ],
                            statisticsAreLoading:
                                isLoadingStatistics
                                && statisticsByEventID[
                                    event.id
                                ] == nil,
                            statisticsUnavailable:
                                statisticsFailedEventIDs
                                .contains(event.id),
                            unfinishedJobCount:
                                jobs.filter { job in
                                    job.stage != .completed
                                }
                                .count,
                            activeJobCount:
                                jobs.filter { job in
                                    switch job.stage {
                                    case .preparing,
                                            .converting,
                                            .uploading:
                                        return true

                                    case .queued,
                                            .prepared,
                                            .readyToUpload,
                                            .completed,
                                            .failed:
                                        return false
                                    }
                                }
                                .count
                        )
                    }
                }
            }
        }
        .navigationTitle("Events")
        .navigationDestination(
            for: PickPicEvent.self
        ) { event in
            EventDetailView(
                event: event,
                onEventUpdated:
                    onEventUpdated,
                onEventStatisticsUpdated:
                    onEventStatisticsUpdated,
                onEventDeleted:
                    onEventDeleted
            )
        }
        .searchable(
            text: $searchText,
            prompt: "Search events"
        )
        .refreshable {
            await onRefresh()
        }
        .toolbar {
            ToolbarItem(
                placement: .topBarLeading
            ) {
                Menu {
                    Picker(
                        "Filter",
                        selection: $selectedFilter
                    ) {
                        ForEach(
                            EventDashboardFilter
                                .allCases
                        ) { filter in
                            Label(
                                filter.title,
                                systemImage:
                                    filter.systemImage
                            )
                            .tag(filter)
                        }
                    }

                    Divider()

                    Picker(
                        "Sort",
                        selection: $selectedSort
                    ) {
                        ForEach(
                            EventDashboardSort
                                .allCases
                        ) { sort in
                            Label(
                                sort.title,
                                systemImage:
                                    sort.systemImage
                            )
                            .tag(sort)
                        }
                    }
                } label: {
                    Label(
                        selectedFilter == .all
                        ? "Filter and Sort"
                        : selectedFilter.title,
                        systemImage:
                            "line.3.horizontal.decrease.circle"
                    )
                }
            }

            ToolbarItem(
                placement: .topBarTrailing
            ) {
                Button {
                    showingCreateEvent = true
                } label: {
                    Label(
                        "New Event",
                        systemImage: "plus"
                    )
                }
            }
        }
        .sheet(
            isPresented: $showingCreateEvent
        ) {
            EventTitleEditorView(
                navigationTitle: "New Event",
                saveButtonTitle: "Create",
                onSave: onCreateEvent
            )
        }
        .overlay {
            if events.isEmpty {
                emptyState
            }
        }
    }

    private var overviewFooterText: String {
        switch selectedFilter {
        case .all:
            return "Statistics for all events."

        case .active:
            return "Draft, open, active, or unfinished events."

        case .draft:
            return "Events whose public galleries are still drafts."

        case .open:
            return "Open galleries accepting requests and comments."

        case .closed:
            return "Closed galleries that remain viewable."

        case .archived:
            return "Archived galleries that are no longer public."
        }
    }

    private func searchMatches(
        _ event: PickPicEvent
    ) -> Bool {
        let query =
        searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !query.isEmpty else {
            return true
        }

        return event.title.localizedCaseInsensitiveContains(
            query
        )
    }

    private func unfinishedJobCount(
        for eventID: String
    ) -> Int {
        uploadQueue.jobs(
            for: eventID
        )
        .filter { job in
            job.stage != .completed
        }
        .count
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading {
            ProgressView(
                "Loading events…"
            )
        } else if let errorMessage {
            ContentUnavailableView {
                Label(
                    "Unable to Load Events",
                    systemImage:
                        "exclamationmark.triangle"
                )
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task {
                        await onRefresh()
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label(
                    "No Events",
                    systemImage:
                        "photo.on.rectangle.angled"
                )
            } description: {
                Text(
                    """
                    Create an event to start importing and \
                    sharing photos.
                    """
                )
            } actions: {
                Button("Create Event") {
                    showingCreateEvent = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private enum EventDashboardFilter:
    String,
    CaseIterable,
    Identifiable
{
    case all
    case active
    case draft
    case open
    case closed
    case archived

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all:
            return "All Events"

        case .active:
            return "Active"

        case .draft:
            return "Draft"

        case .open:
            return "Open"

        case .closed:
            return "Closed"

        case .archived:
            return "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "rectangle.stack"

        case .active:
            return "bolt"

        case .draft:
            return "pencil"

        case .open:
            return "globe"

        case .closed:
            return "checkmark.circle"

        case .archived:
            return "archivebox"
        }
    }

    func matches(
        _ event: PickPicEvent,
        unfinishedJobCount: Int
    ) -> Bool {
        switch self {
        case .all:
            return true

        case .active:
            return unfinishedJobCount > 0
            || event.status == .draft
            || event.status == .uploading
            || event.status == .ready
            || event.status == .editing

        case .draft:
            return event.status == .draft
            || event.status == .uploading
            || event.status == .editing

        case .open:
            return event.status == .ready

        case .closed:
            return event.status == .completed

        case .archived:
            return event.status == .archived
        }
    }
}

private enum EventDashboardSort:
    String,
    CaseIterable,
    Identifiable
{
    case updated
    case created
    case name
    case photos
    case liked

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .updated:
            return "Recently Updated"

        case .created:
            return "Newest Created"

        case .name:
            return "Name"

        case .photos:
            return "Most Photos"

        case .liked:
            return "Most Liked"
        }
    }

    var systemImage: String {
        switch self {
        case .updated:
            return "clock.arrow.circlepath"

        case .created:
            return "calendar"

        case .name:
            return "textformat"

        case .photos:
            return "photo.stack"

        case .liked:
            return "heart"
        }
    }

    func isOrderedBefore(
        _ first: PickPicEvent,
        _ second: PickPicEvent,
        statisticsByEventID:
        [String: EventPhotoStatistics]
    ) -> Bool {
        switch self {
        case .updated:
            if first.updatedAt != second.updatedAt {
                return first.updatedAt > second.updatedAt
            }

        case .created:
            if first.createdAt != second.createdAt {
                return first.createdAt > second.createdAt
            }

        case .name:
            return first.title.localizedStandardCompare(
                second.title
            ) == .orderedAscending

        case .photos:
            let firstCount =
            statisticsByEventID[first.id]?
                .uploadedProofCount
            ?? -1

            let secondCount =
            statisticsByEventID[second.id]?
                .uploadedProofCount
            ?? -1

            if firstCount != secondCount {
                return firstCount > secondCount
            }

        case .liked:
            let firstCount =
            statisticsByEventID[first.id]?
                .likedPhotoCount
            ?? -1

            let secondCount =
            statisticsByEventID[second.id]?
                .likedPhotoCount
            ?? -1

            if firstCount != secondCount {
                return firstCount > secondCount
            }
        }

        return first.title.localizedStandardCompare(
            second.title
        ) == .orderedAscending
    }
}

private struct EventOverview: View {
    let eventCount: Int
    let statistics: EventPhotoStatistics
    let incompleteJobCount: Int
    let showsPlaceholder: Bool

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        LazyVGrid(
            columns: columns,
            spacing: 16
        ) {
            EventOverviewMetric(
                title: "Events",
                value: "\(eventCount)",
                systemImage:
                    "rectangle.stack"
            )

            EventOverviewMetric(
                title: "Proofs",
                value: statisticsValue(
                    statistics.uploadedProofCount
                ),
                systemImage: "photo"
            )

            EventOverviewMetric(
                title: "Liked",
                value: statisticsValue(
                    statistics.likedPhotoCount
                ),
                systemImage: "heart.fill"
            )

            EventOverviewMetric(
                title: "Editing",
                value: statisticsValue(
                    statistics.editingPhotoCount
                ),
                systemImage:
                    "slider.horizontal.3"
            )

            EventOverviewMetric(
                title: "Finals",
                value: statisticsValue(
                    statistics.uploadedFinalCount
                ),
                systemImage:
                    "checkmark.seal.fill"
            )

            EventOverviewMetric(
                title: "Uploads",
                value:
                    "\(incompleteJobCount)",
                systemImage:
                    "clock.arrow.circlepath"
            )
        }
        .padding(.vertical, 8)
    }

    private func statisticsValue(
        _ value: Int
    ) -> String {
        showsPlaceholder ? "—" : "\(value)"
    }
}

private struct EventOverviewMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.tint)

            Text(value)
                .font(.title3.bold())
                .contentTransition(.numericText())

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(
            children: .combine
        )
    }
}

private struct EventRow: View {
    let event: PickPicEvent
    let statistics: EventPhotoStatistics?
    let statisticsAreLoading: Bool
    let statisticsUnavailable: Bool
    let unfinishedJobCount: Int
    let activeJobCount: Int

    private var uploadStatusText: String {
        if activeJobCount > 0 {
            return activeJobCount == 1
            ? "Upload in progress"
            : "\(activeJobCount) uploads in progress"
        }

        return unfinishedJobCount == 1
        ? "1 upload to continue"
        : "\(unfinishedJobCount) uploads to continue"
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.title2)
                .frame(
                    width: 36,
                    height: 36
                )
                .foregroundStyle(.tint)

            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                Text(event.title)
                    .font(.headline)

                Label(
                    event.status.title,
                    systemImage:
                        event.status.systemImage
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                statisticsLine

                if unfinishedJobCount > 0 {
                    Label(
                        uploadStatusText,
                        systemImage:
                            activeJobCount > 0
                        ? "arrow.up.circle.fill"
                        : "clock.arrow.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        activeJobCount > 0
                        ? Color.accentColor
                        : Color.orange
                    )
                }
            }

            Spacer()

            Text(
                event.updatedAt.formatted(
                    date: .abbreviated,
                    time: .omitted
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statisticsLine: some View {
        if let statistics {
            HStack(spacing: 12) {
                EventRowMetric(
                    value:
                        statistics.uploadedProofCount,
                    systemImage: "photo"
                )

                EventRowMetric(
                    value:
                        statistics.likedPhotoCount,
                    systemImage: "heart.fill"
                )

                EventRowMetric(
                    value:
                        statistics.uploadedFinalCount,
                    systemImage:
                        "checkmark.seal.fill"
                )

                if
                    statistics
                        .missingVariantPhotoCount > 0
                {
                    EventRowMetric(
                        value:
                            statistics
                            .missingVariantPhotoCount,
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if statisticsAreLoading {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)

                Text("Loading statistics…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if statisticsUnavailable {
            Label(
                "Statistics unavailable",
                systemImage:
                    "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }
}

private struct EventRowMetric: View {
    let value: Int
    let systemImage: String

    var body: some View {
        Label(
            "\(value)",
            systemImage: systemImage
        )
        .labelStyle(.titleAndIcon)
        .accessibilityLabel(
            "\(value)"
        )
    }
}
