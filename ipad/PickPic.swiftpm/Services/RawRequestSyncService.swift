import Combine
import Foundation

struct RawRequestSyncResult: Sendable {
    let uploadedPhotoCount: Int
    let uploadedByteCount: Int64
    let missingFilenames: [String]
    let failures: [String]
}

/*
 * What LikedPhotosView reads to show per-file progress for the one RAW
 * request sync() is actively working on (#268) -- everywhere else in the
 * pending list still just reads "Waiting", since the queue itself is
 * already the ordered photo list the view has from the server.
 *
 * Deliberately not a persisted model mirroring UploadJob/UploadStage: the
 * server is the durable record of what still needs delivering (see the
 * note atop RawRequestSyncService), so nothing here needs to survive a
 * relaunch on its own. The one exception is reattach(), used when a
 * transfer is found already in flight from a previous process -- that
 * only re-seeds state this process would otherwise have no way to know,
 * it does not persist anything to disk.
 */
@MainActor
final class RawDeliveryProgress: ObservableObject {
    enum Phase: Equatable, Sendable {
        case staging
        case uploading(sentBytes: Int64, totalBytes: Int64)
    }

    static let shared = RawDeliveryProgress()

    @Published private(set) var pendingPhotoIDs: [String] =
        []

    @Published private(set) var currentPhotoID: String?

    @Published private(set) var phase: Phase?

    /*
     * The part-level detail behind phase while currentPhotoID's parts are
     * moving. Kept beside rather than inside Phase so the view's shape --
     * sent over total -- is unchanged by the switch to multipart (#368).
     */
    private var tally: RawUploadProgressTally?

    private init() {}

    fileprivate func begin(pendingPhotoIDs: [String]) {
        self.pendingPhotoIDs = pendingPhotoIDs
    }

    fileprivate func startStaging(photoID: String) {
        currentPhotoID = photoID
        phase = .staging
    }

    fileprivate func beginUpload(
        photoID: String,
        plan: RawUploadPartPlan,
        landedParts: some Sequence<Int>
    ) {
        currentPhotoID = photoID
        tally = RawUploadProgressTally(
            plan: plan,
            landedParts: landedParts
        )
        publishTally()
    }

    /*
     * Every part callback names its photo, and one for a photo that is no
     * longer current is dropped: a cancelled or finished photo's last
     * delegate callbacks can still be in flight to the main actor after the
     * next photo has begun.
     */
    private func updateTally(
        photoID: String,
        _ update: (inout RawUploadProgressTally) -> Void
    ) {
        guard
            photoID == currentPhotoID,
            var tally
        else {
            return
        }

        update(&tally)
        self.tally = tally
        publishTally()
    }

    private func publishTally() {
        guard let tally else {
            return
        }

        phase = .uploading(
            sentBytes: tally.sentBytes,
            totalBytes: tally.totalBytes
        )
    }

    fileprivate func finish(photoID: String) {
        pendingPhotoIDs.removeAll { pendingPhotoID in
            pendingPhotoID == photoID
        }

        if currentPhotoID == photoID {
            currentPhotoID = nil
            phase = nil
            tally = nil
        }
    }

    /*
     * Re-seeds state for a transfer this process did not start itself --
     * RawUploadSession.reattachActiveUpload found it still running under a
     * relaunched background session. Without this the row for that photo
     * would show "Waiting" while 100 MB moved quietly in the background.
     *
     * Every part in the plan without a running task is counted as landed.
     * That is what it almost always means -- the parts were all queued
     * together -- and a part that in fact failed only overstates the bar
     * until the next sweep asks /raw/start and re-sends it.
     */
    fileprivate func reattach(
        tag: RawPartTaskTag,
        activeParts: Set<Int>,
        pendingPhotoIDs: [String]
    ) {
        self.pendingPhotoIDs = pendingPhotoIDs

        let plan = tag.plan

        beginUpload(
            photoID: tag.photoID,
            plan: plan,
            landedParts: (plan.partNumbers.map(Array.init) ?? [])
                .filter { partNumber in
                    !activeParts.contains(partNumber)
                }
        )
    }

    fileprivate func reset() {
        pendingPhotoIDs = []
        currentPhotoID = nil
        phase = nil
        tally = nil
    }

    /*
     * The entry points every part callback below actually uses.
     * RawUploadSession's didSendBodyData fires from its own delegate queue,
     * and the part uploads run in task-group children off the main actor,
     * so a closure that touched the tally directly would be
     * isolation-unsafe. Being nonisolated lets a plain @Sendable closure call
     * these synchronously from any thread; the actual mutation still only
     * ever happens on the main actor, inside the Task.
     */
    nonisolated static func schedulePartSent(
        photoID: String,
        partNumber: Int,
        sentBytes: Int64
    ) {
        Task { @MainActor in
            RawDeliveryProgress.shared.updateTally(
                photoID: photoID
            ) { tally in
                tally.recordSent(sentBytes, forPart: partNumber)
            }
        }
    }

    nonisolated static func schedulePartLanded(
        photoID: String,
        partNumber: Int
    ) {
        Task { @MainActor in
            RawDeliveryProgress.shared.updateTally(
                photoID: photoID
            ) { tally in
                tally.markLanded(partNumber)
            }
        }
    }

    nonisolated static func schedulePartFailed(
        photoID: String,
        partNumber: Int
    ) {
        Task { @MainActor in
            RawDeliveryProgress.shared.updateTally(
                photoID: photoID
            ) { tally in
                tally.markFailed(partNumber)
            }
        }
    }
}

extension RawDeliveryProgress.Phase {
    /*
     * A 0...1 fraction for a determinate ProgressView, or nil when there is
     * nothing meaningful to show a bar for: still staging (no bytes sent
     * yet), or a zero total, which only an empty file -- one the server
     * refuses anyway -- can produce now that the total is the file's own
     * size rather than URLSession's per-request estimate. Clamped as a last
     * line of defence; RawUploadProgressTally already caps each part at its
     * own size.
     */
    var fractionCompleted: Double? {
        switch self {
        case .staging:
            return nil

        case let .uploading(sentBytes, totalBytes):
            guard totalBytes > 0 else {
                return nil
            }

            let fraction =
                Double(sentBytes) / Double(totalBytes)

            return min(max(fraction, 0), 1)
        }
    }
}

/*
 * Delivers the original RAW for every photo in an event that a gallery viewer
 * has asked for and that has not been delivered yet (issue #205).
 *
 * The RAW-request twin of RequestedPhotoSyncService: same polling entry point,
 * same reentrancy guard, but where that one copies a hearted photo's RAW into
 * the local To Edit folder, this one sends the bytes to the server. This is
 * the only path on which a full original leaves the device.
 *
 * Firing it automatically is safe because the pass is idempotent by
 * construction. A failed or interrupted upload leaves
 * raw_requests.fulfilled_at null, so the next activation simply finds the
 * request still pending and tries again; a delivered one comes back with
 * rawPhoto set and is skipped. A failed part is retried in-process with
 * backoff (#368), but beyond that there is deliberately no local retry
 * queue — the server is the record of what still needs doing, down to which
 * parts of an interrupted upload are still missing.
 */
@MainActor
enum RawRequestSyncService {
    private static var activeEventIDs: Set<String> = []

    static func sync(
        eventID: String,
        reference: EventFolderReference,
        using client: APIClient,
        photos: [ServerPhotoRecord]? = nil
    ) async throws -> RawRequestSyncResult? {
        guard activeEventIDs.insert(eventID).inserted else {
            return nil
        }

        defer {
            activeEventIDs.remove(eventID)
        }

        let currentPhotos:
        [ServerPhotoRecord]

        if let photos {
            currentPhotos = photos
        } else {
            currentPhotos =
            try await client.fetchEventPhotos(
                eventID: eventID
            )
        }

        let photosNeedingRaw =
        currentPhotos
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

        guard !photosNeedingRaw.isEmpty else {
            RawDeliveryProgress.shared.reset()
            return nil
        }

        /*
         * A relaunch can land while iPadOS is still finishing a transfer the
         * previous process started. That upload has not reached the server
         * yet, so its request still reads as pending — staging and sending it
         * again would push the same RAW twice.
         *
         * Those transfers -- one per part still queued (#368) -- are worth
         * showing progress for, though (#268). reattachActiveUploads finds
         * them, tags a handler onto each, and hands back the tag and the
         * parts still running so the view has something other than
         * "Waiting" for the photo.
         */
        guard
            await !RawUploadSession.shared
                .hasActiveUploads()
        else {
            if
                RawDeliveryProgress.shared.currentPhotoID
                    == nil,
                let reattached =
                    await RawUploadSession.shared
                    .reattachActiveUploads(
                        onProgress: { tag, sentBytes in
                            RawDeliveryProgress.schedulePartSent(
                                photoID: tag.photoID,
                                partNumber: tag.partNumber,
                                sentBytes: sentBytes
                            )
                        }
                    ),
                photosNeedingRaw.contains(where: { photo in
                    photo.id == reattached.tag.photoID
                })
            {
                RawDeliveryProgress.shared.reattach(
                    tag: reattached.tag,
                    activeParts: reattached.activeParts,
                    pendingPhotoIDs:
                        photosNeedingRaw.map(\.id)
                )
            }

            return nil
        }

        RawDeliveryProgress.shared.begin(
            pendingPhotoIDs: photosNeedingRaw.map(\.id)
        )

        var uploadedPhotoCount = 0
        var uploadedByteCount: Int64 = 0
        var missingFilenames: [String] = []
        var failures: [String] = []

        for photo in photosNeedingRaw {
            guard !Task.isCancelled else {
                break
            }

            RawDeliveryProgress.shared.startStaging(
                photoID: photo.id
            )

            let staged: StagedRawUpload

            do {
                staged = try await stage(
                    photo: photo,
                    reference: reference,
                    partSize: RawUploadPartPlan.defaultPartSize
                )
            } catch RawUploadFileError
                .fileMissing(let filename)
            {
                /*
                 * Reported rather than thrown. A RAW that has been moved off
                 * the iPad is a fact about one photo, not a reason to abandon
                 * the rest of the event's requests.
                 */
                missingFilenames.append(filename)
                RawDeliveryProgress.shared.finish(
                    photoID: photo.id
                )
                continue
            } catch {
                failures.append(
                    photo.originalFilename
                )

                RawDeliveryProgress.shared.finish(
                    photoID: photo.id
                )
                continue
            }

            do {
                uploadedByteCount += try await deliver(
                    staged,
                    photo: photo,
                    reference: reference,
                    using: client
                )

                uploadedPhotoCount += 1
            } catch {
                failures.append(
                    photo.originalFilename
                )
            }

            RawDeliveryProgress.shared.finish(
                photoID: photo.id
            )

            /*
             * Removed whether or not the upload succeeded: a retry re-stages
             * from the event folder, and these are the largest files the app
             * ever writes into its own container.
             */
            try? RawUploadFileService.removeStagedFile(
                photoID: photo.id
            )
        }

        RawDeliveryProgress.shared.reset()

        return RawRequestSyncResult(
            uploadedPhotoCount: uploadedPhotoCount,
            uploadedByteCount: uploadedByteCount,
            missingFilenames: missingFilenames,
            failures: failures
        )
    }

    private static func stage(
        photo: ServerPhotoRecord,
        reference: EventFolderReference,
        partSize: Int64
    ) async throws -> StagedRawUpload {
        let photoID = photo.id
        let filename = photo.originalFilename

        return try await Task.detached(
            priority: .userInitiated
        ) {
            try RawUploadFileService.stage(
                photoID: photoID,
                filename: filename,
                reference: reference,
                partSize: partSize
            )
        }
        .value
    }

    /*
     * Sends one staged RAW as a multipart upload (#362/#368) and returns its
     * byte size once every part has landed -- at which point the server has
     * already completed the upload from inside the last part's request.
     *
     * Every part the server reports missing is queued at once, each as its
     * own background task. That is what lets iPadOS carry the whole file
     * with the app suspended: nothing here has to run again to send the next
     * part or to finish. Awaiting them all is only for this process's own
     * bookkeeping -- the result and the progress bar -- while it happens to
     * still be alive.
     */
    private static func deliver(
        _ initiallyStaged: StagedRawUpload,
        photo: ServerPhotoRecord,
        reference: EventFolderReference,
        using client: APIClient
    ) async throws -> Int64 {
        var staged = initiallyStaged
        var start = try await client.startRawUpload(staged)

        /*
         * Staging had to split before the server had said anything, because
         * start needs the hash that the split computes. If the server has
         * chosen a different part size, re-split once at its size and ask
         * again. The hash is of the whole file, so it only changes if the
         * file itself did in between, and then start simply restarts for the
         * new bytes.
         */
        if start.partSize != staged.partSize, start.partSize > 0 {
            staged = try await stage(
                photo: photo,
                reference: reference,
                partSize: start.partSize
            )

            start = try await client.startRawUpload(staged)
        }

        guard
            start.partSize == staged.partSize,
            start.partCount == staged.plan.partCount
        else {
            throw RawRequestSyncError.partPlanMismatch(
                staged.filename
            )
        }

        RawDeliveryProgress.shared.beginUpload(
            photoID: staged.photoID,
            plan: staged.plan,
            landedParts: start.landedParts
        )

        let partsToSend =
        staged.plan.partsToSend(
            landedParts: start.landedParts
        )

        let sendingStaged = staged

        let allLanded =
        try await withThrowingTaskGroup(
            of: Bool.self
        ) { group in
            for partNumber in partsToSend {
                group.addTask {
                    try await uploadPart(
                        sendingStaged,
                        partNumber: partNumber,
                        using: client
                    )
                }
            }

            var allLanded = true

            do {
                for try await landed in group {
                    allLanded = allLanded && landed
                }
            } catch {
                /*
                 * A part failed for a reason no retry can fix. Its siblings
                 * could only fail the same way or land bytes for an upload
                 * this pass is abandoning, and URLSession tasks do not
                 * observe Swift cancellation -- so they are cancelled
                 * explicitly, before the group waits on them.
                 */
                group.cancelAll()

                await RawUploadSession.shared.cancelUploads(
                    photoID: sendingStaged.photoID
                )

                throw error
            }

            return allLanded
        }

        /*
         * Some part ran out of retries. Everything that did land is kept
         * server-side, so the next sync's start reports only the stragglers.
         */
        guard allLanded else {
            throw RawRequestSyncError.partsIncomplete(
                staged.filename
            )
        }

        return staged.byteSize
    }

    /*
     * One part, retried on its own with backoff when the failure is one a
     * retry can fix. Never restarts the file: its siblings are unaffected,
     * and the server already holds whatever has landed. Returns false when
     * retries run out, and throws for a failure that retrying cannot change
     * (a 401, the storage cap, an upload the server no longer has).
     */
    nonisolated private static func uploadPart(
        _ staged: StagedRawUpload,
        partNumber: Int,
        using client: APIClient
    ) async throws -> Bool {
        let photoID = staged.photoID

        for attempt in 1...RawPartRetryPolicy.maximumAttempts {
            try Task.checkCancellation()

            do {
                try await client.uploadRawPart(
                    staged,
                    partNumber: partNumber,
                    onProgress: { sentBytes, _ in
                        RawDeliveryProgress.schedulePartSent(
                            photoID: photoID,
                            partNumber: partNumber,
                            sentBytes: sentBytes
                        )
                    }
                )

                RawDeliveryProgress.schedulePartLanded(
                    photoID: photoID,
                    partNumber: partNumber
                )

                return true
            } catch {
                RawDeliveryProgress.schedulePartFailed(
                    photoID: photoID,
                    partNumber: partNumber
                )

                guard RawPartRetryPolicy.isRetryable(error) else {
                    throw error
                }

                guard
                    let delay = RawPartRetryPolicy.delay(
                        afterAttempt: attempt
                    )
                else {
                    return false
                }

                try await Task.sleep(for: delay)
            }
        }

        return false
    }
}

/*
 * When a failed RAW part is worth sending again (#368). Pure, so the
 * classification is tested rather than trusted.
 */
enum RawPartRetryPolicy {
    static let maximumAttempts = 5

    /* 2, 4, 8, 16 seconds; nil once the attempts are spent. */
    static func delay(afterAttempt attempt: Int) -> Duration? {
        guard
            attempt >= 1,
            attempt < maximumAttempts
        else {
            return nil
        }

        return .seconds(1 << attempt)
    }

    /*
     * Transport failures and the server's transient statuses are retried.
     * Every other status means the request itself is wrong for the server's
     * current state -- a part of the wrong size, a session /raw/start has
     * since replaced, the account's storage cap -- and resending the same
     * bytes can only fail the same way; the next sync's start is what
     * repairs those. A 401 in particular must not be retried: the credential
     * has already been cleared (APIClient.sessionAwareError).
     */
    static func isRetryable(_ error: Error) -> Bool {
        if let apiError = error as? APIClientError {
            guard case let .server(statusCode, _) = apiError else {
                return false
            }

            return statusCode == 408
                || statusCode == 429
                || (500..<600).contains(statusCode)
        }

        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }

        return false
    }
}

enum RawRequestSyncError: LocalizedError {
    case partPlanMismatch(String)
    case partsIncomplete(String)

    var errorDescription: String? {
        switch self {
        case let .partPlanMismatch(filename):
            return """
            The server split \(filename) into different parts than \
            PickPic did, so its RAW was not sent.
            """

        case let .partsIncomplete(filename):
            return """
            Some parts of \(filename) could not be sent. The rest were \
            kept and the missing ones will be retried.
            """
        }
    }
}
