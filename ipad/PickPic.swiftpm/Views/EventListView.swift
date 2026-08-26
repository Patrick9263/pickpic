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

    @Binding var selectedEventID: String?

    let onRefresh: () async -> Void
    let onCreateEvent:
    (String) async throws -> Void

    @EnvironmentObject private var uploadQueue:
    UploadQueueStore

    @State private var showingCreateEvent = false
    @State private var searchText = ""

    /*
     * Filter and sort persist across launches because they are the only
     * way to organise the sidebar; a search term does not, since it is a
     * momentary lookup rather than a chosen arrangement. An unrecognised
     * stored value — a case renamed in a later build — falls back to the
     * default rather than leaving the sidebar in a state with no picker
     * entry selected.
     */
    @AppStorage("eventSidebar.filter")
    private var selectedFilter:
    EventDashboardFilter = .all

    @AppStorage("eventSidebar.sort")
    private var selectedSort:
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

    var body: some View {
        List(selection: $selectedEventID) {
            /*
             * List selection has no deselect gesture, so without a row
             * that clears it the All Events summary and its storage
             * figures are unreachable the moment an event is tapped.
             */
            Section {
                Button {
                    selectedEventID = nil
                } label: {
                    HStack {
                        Label(
                            "All Events",
                            systemImage:
                                "square.grid.2x2"
                        )

                        Spacer()

                        if selectedEventID == nil {
                            Image(
                                systemName: "checkmark"
                            )
                            .font(
                                .footnote
                                    .weight(.semibold)
                            )
                            .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

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
                    /*
                     * Tagged rather than wrapped in a link, so the
                     * sidebar drives the detail column instead of
                     * pushing over itself. In compact width the split
                     * view collapses and this still reads as a push.
                     */
                    Group {
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
                            /*
                             * A job waiting on connectivity also carries
                             * a lastFailure, but it resumes on its own
                             * and is not something to walk back to the
                             * iPad for. Only a job that has stopped for
                             * good counts as needing attention.
                             */
                            stalledJobCount:
                                jobs.filter { job in
                                    job.stage == .failed
                                    || (
                                        job.stage
                                            == .readyToUpload
                                        && job.uploadProgress
                                            .lastFailure != nil
                                        && !job.uploadProgress
                                            .isWaitingForConnectivity
                                    )
                                }
                                .count,
                            activeJobCount:
                                jobs.filter { job in
                                    switch job.stage {
                                    case .preparing,
                                            .preflighting,
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
                    .tag(event.id)
                }
            }
        }
        .navigationTitle("Events")
        /*
         * A large title sits on its own line instead of competing with
         * the filter, settings, add and sidebar controls, which in a
         * narrow sidebar left room for only "Ev…".
         */
        .navigationBarTitleDisplayMode(.large)
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
                    /*
                     * A persisted filter can be days old by the time the
                     * app is next opened, so the control fills in when
                     * one is hiding events. Without that the sidebar just
                     * looks short.
                     */
                    Label(
                        selectedFilter == .all
                        ? "Filter and Sort"
                        : selectedFilter.title,
                        systemImage:
                            selectedFilter == .all
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
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
            || event.status == .ready

        case .draft:
            return event.status == .draft

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

/*
 * Shown in the detail column when no event is selected, where an
 * all-events summary has room to breathe. It previously sat at the top
 * of the sidebar and pushed the events themselves out of view.
 */
struct EventOverview: View {
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

/*
 * The all-events counterpart to the web dashboard's storage panel, drawn
 * from the same /api/admin/storage figures so the two faces agree. It
 * loads itself rather than being fed by EventListViewModel, because
 * nothing else on the screen depends on the numbers and a failure here
 * must not disturb the event list.
 */
struct StorageUsagePanel: View {
    @EnvironmentObject private var configuration:
    APIConfigurationStore

    @State private var storage: StorageUsageRecord?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        Section {
            content
        } header: {
            HStack {
                Text("Cloudflare Storage")

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if configuration.isConfigured {
                    Button {
                        Task { await load() }
                    } label: {
                        Label(
                            "Refresh Storage",
                            systemImage:
                                "arrow.clockwise"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } footer: {
            Text(
                """
                These sizes come from what the database recorded for each \
                stored file, not from R2 itself, so they can drift if a \
                delete ever half-failed.
                """
            )
        }
        .task {
            /*
             * Only the first appearance fetches. Returning to All Events
             * after visiting an event keeps whatever was measured, so
             * moving around the app does not re-run the aggregate.
             */
            guard storage == nil else {
                return
            }

            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let storage {
            totals(for: storage)

            if storage.events.isEmpty {
                Text(
                    "Nothing is stored yet. Upload a shoot and it will appear here."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                ForEach(storage.events) { eventStorage in
                    StorageEventRow(
                        eventStorage: eventStorage,
                        largestEventBytes:
                            largestEventBytes(
                                in: storage
                            )
                    )
                }
            }
        } else if let errorMessage {
            Label(
                errorMessage,
                systemImage:
                    "exclamationmark.triangle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
            /*
             * Also covers the moment before the first fetch starts, so
             * the section always has a row and never collapses to a bare
             * header while it is measuring.
             */
            Text("Measuring stored photos…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func totals(
        for storage: StorageUsageRecord
    ) -> some View {
        VStack(spacing: 2) {
            Text(
                StorageUsagePanel.formattedBytes(
                    storage.totalBytes
                )
            )
            .font(.largeTitle.bold())
            .contentTransition(.numericText())

            Text("stored in R2")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)

        LazyVGrid(
            columns: columns,
            spacing: 16
        ) {
            StorageMetric(
                title: "Proofs",
                value: StorageUsagePanel.formattedBytes(
                    storage.proofBytes
                ),
                detail: StorageUsagePanel.formattedCount(
                    storage.photoCount,
                    noun: "photo"
                ),
                systemImage: "photo"
            )

            StorageMetric(
                title: "Finals",
                value: StorageUsagePanel.formattedBytes(
                    storage.finalBytes
                ),
                detail: StorageUsagePanel.formattedCount(
                    storage.finalCount,
                    noun: "edit"
                ),
                systemImage: "checkmark.seal.fill"
            )

            StorageMetric(
                title: "Previews",
                value: StorageUsagePanel.formattedBytes(
                    storage.variantBytes
                ),
                detail: StorageUsagePanel.formattedCount(
                    storage.variantCount,
                    noun: "variant"
                ),
                systemImage:
                    "square.stack.3d.down.right"
            )
        }
        .padding(.vertical, 8)
    }

    /*
     * Scaled against the largest event rather than the total, so the
     * smaller shoots stay visible next to a dominant one.
     */
    private func largestEventBytes(
        in storage: StorageUsageRecord
    ) -> Int64 {
        storage.events.reduce(0) { largest, eventStorage in
            max(largest, eventStorage.totalBytes)
        }
    }

    private func load() async {
        guard configuration.isConfigured else {
            errorMessage = """
            Open Connection Settings to measure stored photos.
            """

            return
        }

        guard !isLoading else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let client = try configuration.makeClient()

            storage = try await client.fetchStorageUsage()
            errorMessage = nil
        } catch {
            /*
             * A previous measurement is better than an empty panel, so a
             * failed refresh leaves whatever was already shown in place.
             */
            if storage == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    static func formattedBytes(
        _ byteCount: Int64
    ) -> String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    static func formattedCount(
        _ value: Int,
        noun: String
    ) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

private struct StorageMetric: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.tint)

            Text(value)
                .font(.subheadline.bold())
                .contentTransition(.numericText())

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(
            children: .combine
        )
    }
}

private struct StorageEventRow: View {
    let eventStorage: EventStorageRecord
    let largestEventBytes: Int64

    private var share: Double {
        guard largestEventBytes > 0 else {
            return 0
        }

        return Double(eventStorage.totalBytes)
        / Double(largestEventBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(eventStorage.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(
                    StorageUsagePanel.formattedBytes(
                        eventStorage.totalBytes
                    )
                )
                .font(
                    .subheadline
                        .monospacedDigit()
                )
            }

            ProgressView(value: share)
                .progressViewStyle(.linear)

            Text(detailSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detailSummary: String {
        var parts = [
            eventStorage.status.capitalized,
            StorageUsagePanel.formattedCount(
                eventStorage.photoCount,
                noun: "proof"
            )
        ]

        if eventStorage.finalCount > 0 {
            parts.append(
                StorageUsagePanel.formattedCount(
                    eventStorage.finalCount,
                    noun: "final"
                )
            )
        }

        return parts.joined(separator: " · ")
    }
}

private struct EventRow: View {
    let event: PickPicEvent
    let statistics: EventPhotoStatistics?
    let statisticsAreLoading: Bool
    let statisticsUnavailable: Bool
    let unfinishedJobCount: Int
    let stalledJobCount: Int
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
                    .lineLimit(2)

                /*
                 * The date shares the status line rather than occupying
                 * a column of its own. As a separate column it competed
                 * with the text for a narrow sidebar's width, wrapping
                 * titles onto a third line and truncating the metrics
                 * below to bare icons.
                 */
                HStack(spacing: 8) {
                    Label(
                        event.status.title,
                        systemImage:
                            event.status.systemImage
                    )

                    Spacer(minLength: 4)

                    Text(
                        event.updatedAt.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                    .fixedSize()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if event.needsRemoteCreation {
                    Label(
                        "On this iPad only",
                        systemImage: "icloud.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                statisticsLine

                if stalledJobCount > 0 {
                    Label(
                        stalledJobCount == 1
                        ? "1 photo needs attention"
                        : "\(stalledJobCount) photos need attention",
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                } else if unfinishedJobCount > 0 {
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

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statisticsLine: some View {
        if let statistics {
            /*
             * Wider than the 3pt inside a metric, so each number reads
             * as belonging to the icon on its left.
             */
            HStack(spacing: 14) {
                EventRowMetric(
                    value:
                        statistics.uploadedProofCount,
                    systemImage: "photo",
                    name: "proofs"
                )

                EventRowMetric(
                    value:
                        statistics.likedPhotoCount,
                    systemImage: "heart.fill",
                    name: "liked"
                )

                EventRowMetric(
                    value:
                        statistics.uploadedFinalCount,
                    systemImage:
                        "checkmark.seal.fill",
                    name: "finals"
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
                            "exclamationmark.triangle.fill",
                        name: "needing web versions"
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

    /*
     * What the icon means, for anyone who cannot see it. Without this
     * the row announces as a run of bare numbers.
     */
    let name: String

    var body: some View {
        /*
         * Built by hand rather than as a Label so the gap between an
         * icon and its own number stays tighter than the gap between one
         * metric and the next. A Label's default spacing made the two
         * read as evenly spaced, so the numbers did not obviously belong
         * to the icons beside them.
         */
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .imageScale(.small)

            Text("\(value)")
                .monospacedDigit()
        }
        /*
         * Keeps each icon and its number together. Without this a
         * narrow sidebar drops the numbers and leaves a row of icons at
         * uneven spacing, which reads as a layout fault rather than as
         * missing data.
         */
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(value) \(name)"
        )
    }
}
