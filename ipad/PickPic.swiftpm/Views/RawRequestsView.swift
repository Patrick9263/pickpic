import SwiftUI

/*
 * Everything about viewers asking for originals, in one place (#373).
 * This used to be a section inside LikedPhotosView, with the on/off
 * controls in EventDetailView's settings — but a heart is an edit request
 * and a RAW request is a delivery, two different jobs, and a pending
 * delivery sitting under the edit queue was easy to miss.
 */
struct RawRequestsView: View {
    @State private var event: PickPicEvent

    let onEventUpdated:
    (PickPicEvent) -> Void

    @EnvironmentObject private var configuration:
    APIConfigurationStore

    @EnvironmentObject private var eventFolders:
    EventFolderStore

    @EnvironmentObject private var rawRequestStatus:
    RawRequestStatusStore

    @StateObject private var viewModel =
    RawRequestsViewModel()

    /*
     * A singleton rather than an @EnvironmentObject (#268): the one thing
     * that writes it, RawRequestSyncService.sync, is only ever invoked
     * from App.swift's automatic sweep, several layers away from this
     * view, and threading a new environment object through there just to
     * read it back here would be a bigger diff for no behavioral gain.
     */
    @ObservedObject private var rawDeliveryProgress =
    RawDeliveryProgress.shared

    @State private var showingStopOfferingConfirmation = false
    @State private var isStoppingOffering = false
    @State private var isUpdatingEnabled = false
    @State private var actionErrorTitle = ""
    @State private var actionErrorMessage: String?

    init(
        event: PickPicEvent,
        onEventUpdated:
        @escaping (PickPicEvent) -> Void
    ) {
        _event = State(
            initialValue: event
        )

        self.onEventUpdated =
        onEventUpdated
    }

    var body: some View {
        List {
            controlsSection

            pendingSection

            deliveredSection

            if let errorMessage =
                viewModel.errorMessage {
                Section {
                    Label(
                        errorMessage,
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("RAW Requests")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await load()
        }
        .toolbar {
            ToolbarItem(
                placement: .topBarTrailing
            ) {
                Button {
                    Task {
                        await load()
                    }
                } label: {
                    Label(
                        "Refresh",
                        systemImage:
                            "arrow.clockwise"
                    )
                }
                .disabled(viewModel.isLoading)
            }
        }
        .task(id: event.id) {
            await load()
        }
        /*
         * A RAW the automatic sweep delivered has to move from Pending
         * to Delivered rather than sit on "Waiting".
         */
        .onChange(
            of: rawDeliveryProgress.lastDelivery
        ) { _, delivery in
            guard delivery?.eventID == event.id else {
                return
            }

            Task {
                await load()
            }
        }
        .alert(
            "Stop Offering Originals for \(event.title)?",
            isPresented:
                $showingStopOfferingConfirmation
        ) {
            Button(
                "Stop Offering Originals",
                role: .destructive
            ) {
                Task {
                    await stopOffering()
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                This cancels every pending RAW delivery for this event and \
                frees the storage now, regardless of collection status. \
                Requests stay off until you turn them back on.
                """
            )
        }
        .alert(
            actionErrorTitle,
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        actionErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private func load() async {
        await viewModel.load(
            eventID: event.id,
            using: configuration
        )
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            Toggle(
                "Allow Viewers to Request Originals",
                isOn: enabledBinding
            )
            .disabled(isUpdatingEnabled)

            Button {
                showingStopOfferingConfirmation = true
            } label: {
                Label(
                    "Stop Offering Originals",
                    systemImage: "stop.circle"
                )
            }
            .disabled(isStoppingOffering)
        } footer: {
            Text(
                """
                Turning requests off does not take back a RAW already \
                delivered to a viewer -- use Stop Offering Originals \
                to also cancel every pending delivery and free all \
                storage for this event now, regardless of collection \
                status. Both are reversible: turn requests back on and \
                the next request re-uploads.
                """
            )
        }
    }

    /*
     * event.rawRequestsEnabled is optional (nil until the server has been
     * asked at least once, see PickPicEvent), so this reads nil as "on" --
     * the same default the model documents -- rather than exposing the
     * optionality to the Toggle, and writes go through setEnabled(_:) so a
     * failed request reverts the switch.
     */
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { event.rawRequestsEnabled ?? true },
            set: { newValue in
                Task {
                    await setEnabled(newValue)
                }
            }
        )
    }

    private func setEnabled(
        _ enabled: Bool
    ) async {
        guard !isUpdatingEnabled else {
            return
        }

        isUpdatingEnabled = true

        defer {
            isUpdatingEnabled = false
        }

        do {
            let client =
            try configuration.makeClient()

            let updatedEvent =
            try await client.setRawRequestsEnabled(
                enabled,
                for: event.id
            )

            event = updatedEvent
            onEventUpdated(updatedEvent)
        } catch {
            actionErrorTitle = "Unable to Update RAW Requests"
            actionErrorMessage = error.localizedDescription
        }
    }

    private func stopOffering() async {
        guard !isStoppingOffering else {
            return
        }

        isStoppingOffering = true

        defer {
            isStoppingOffering = false
        }

        do {
            let client =
            try configuration.makeClient()

            let updatedEvent =
            try await client.stopOfferingRawRequests(
                eventID: event.id
            )

            event = updatedEvent
            onEventUpdated(updatedEvent)

            await load()
        } catch {
            actionErrorTitle = "Unable to Stop Offering Originals"
            actionErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Pending

    /*
     * Answers "what has been asked for and not yet sent?" (#217). Before
     * that, needsRawUpload was computed server-side and consumed entirely
     * inside the background sweep — nothing rendered it, so the only
     * in-app signal was a toast that appeared after a delivery already
     * succeeded.
     */
    private var pendingSection: some View {
        Section {
            if
                viewModel.isLoading,
                viewModel.photos.isEmpty
            {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if viewModel.pendingPhotos.isEmpty {
                Label(
                    "Nothing outstanding",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.secondary)
            } else {
                /*
                 * The sweep reads RAWs out of the event folder through its
                 * bookmark, and skips an event that has none on this iPad
                 * — so without this, every row would read "Waiting"
                 * indefinitely with nothing saying why.
                 */
                if eventFolders.reference(for: event.id) == nil {
                    Label(
                        "No event folder is linked on this iPad, so these can't be sent. Choose one from Liked Photos.",
                        systemImage: "folder.badge.questionmark"
                    )
                    .foregroundStyle(.orange)
                }

                ForEach(
                    viewModel.pendingPhotos
                ) { photo in
                    pendingRow(for: photo)
                }
            }

            if let failure =
                rawRequestStatus
                    .failuresByEventID[event.id] {
                if !failure.failedFilenames.isEmpty {
                    Label(
                        "Delivery failed: "
                        + failure.failedFilenames
                            .joined(separator: ", "),
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                }

                if !failure.missingFilenames.isEmpty {
                    Label(
                        "Not found in the event folder: "
                        + failure.missingFilenames
                            .joined(separator: ", "),
                        systemImage:
                            "questionmark.folder"
                    )
                    .foregroundStyle(.orange)
                }

                LabeledContent(
                    "As of",
                    value:
                        failure.checkedAt
                        .formatted(
                            date: .omitted,
                            time: .shortened
                        )
                )
                .foregroundStyle(.secondary)
            }
        } header: {
            Text(
                "Pending (\(viewModel.pendingPhotos.count))"
            )
        } footer: {
            Text(
                "Originals PickPic sends automatically to viewers who asked for them. A failure or a missing file here clears once it's resolved and the next automatic check runs."
            )
        }
    }

    /*
     * Byte-level progress for the one file RawRequestSyncService.sync is
     * actively staging or sending; every other row just reads "Waiting" --
     * the ordered list above is already the queue, so no per-row state is
     * needed for anything but the active upload (#268). A static
     * "Uploading…" on what can be a 100 MB transfer is indistinguishable
     * from a hang, especially over cellular.
     */
    @ViewBuilder
    private func pendingRow(
        for photo: ServerPhotoRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(photo.originalFilename)

            if
                rawDeliveryProgress.currentPhotoID
                    == photo.id,
                let phase = rawDeliveryProgress.phase
            {
                activeUploadStatus(for: phase)
            } else {
                Text("Waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func activeUploadStatus(
        for phase: RawDeliveryProgress.Phase
    ) -> some View {
        switch phase {
        case .staging:
            Label("Staging…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)

        case let .uploading(sentBytes, totalBytes):
            if let fraction = phase.fractionCompleted {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: fraction)

                    Text(
                        "\(Self.byteCount(sentBytes)) of \(Self.byteCount(totalBytes))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Label(
                    "Uploading…",
                    systemImage: "arrow.up.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Delivered

    /*
     * Only shown once there is something in it: an empty "Delivered"
     * under an empty "Pending" is just a second way of saying nothing has
     * been asked for.
     */
    @ViewBuilder
    private var deliveredSection: some View {
        if !viewModel.deliveredPhotos.isEmpty {
            Section {
                ForEach(
                    viewModel.deliveredPhotos
                ) { photo in
                    deliveredRow(for: photo)
                }
            } header: {
                Text(
                    "Delivered (\(viewModel.deliveredPhotos.count))"
                )
            } footer: {
                Text(
                    "Originals already stored for viewers to download. Stop Offering Originals frees them."
                )
            }
        }
    }

    @ViewBuilder
    private func deliveredRow(
        for photo: ServerPhotoRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(photo.originalFilename)

            if let rawPhoto = photo.rawPhoto {
                Text(
                    deliveredDescription(for: rawPhoto)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func deliveredDescription(
        for rawPhoto: ServerRawPhotoSummary
    ) -> String {
        let size = Self.byteCount(rawPhoto.byteSize)

        guard
            let uploadedAt = Self.parseTimestamp(
                rawPhoto.uploadedAt
            )
        else {
            return size
        }

        return "\(size) · \(uploadedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private static func byteCount(
        _ bytes: Int64
    ) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    /*
     * The worker writes uploadedAt with JavaScript's toISOString(), which
     * always carries milliseconds; the plain form is tried as well so a
     * differently-formatted value just drops the date rather than the row.
     */
    private static func parseTimestamp(
        _ value: String
    ) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]

        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]

        return formatter.date(from: value)
    }
}
