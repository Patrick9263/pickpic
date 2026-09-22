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

    private init() {}

    fileprivate func begin(pendingPhotoIDs: [String]) {
        self.pendingPhotoIDs = pendingPhotoIDs
    }

    fileprivate func startStaging(photoID: String) {
        currentPhotoID = photoID
        phase = .staging
    }

    fileprivate func updateProgress(
        sentBytes: Int64,
        totalBytes: Int64
    ) {
        phase = .uploading(
            sentBytes: sentBytes,
            totalBytes: totalBytes
        )
    }

    fileprivate func finish(photoID: String) {
        pendingPhotoIDs.removeAll { pendingPhotoID in
            pendingPhotoID == photoID
        }

        if currentPhotoID == photoID {
            currentPhotoID = nil
            phase = nil
        }
    }

    /*
     * Re-seeds state for a transfer this process did not start itself --
     * RawUploadSession.reattachActiveUpload found it still running under a
     * relaunched background session. Without this the row for that photo
     * would show "Waiting" while 100 MB moved quietly in the background.
     */
    fileprivate func reattach(
        photoID: String,
        pendingPhotoIDs: [String]
    ) {
        self.pendingPhotoIDs = pendingPhotoIDs
        currentPhotoID = photoID
        phase = .uploading(sentBytes: 0, totalBytes: 0)
    }

    fileprivate func reset() {
        pendingPhotoIDs = []
        currentPhotoID = nil
        phase = nil
    }

    /*
     * The entry point every onProgress closure below actually captures.
     * RawUploadSession's didSendBodyData fires from its own delegate
     * queue, not the main actor, so a closure that calls updateProgress
     * directly would be isolation-unsafe to hand to it. Being nonisolated
     * lets a plain @Sendable closure call this synchronously from any
     * thread; the actual mutation still only ever happens on the main
     * actor, inside the Task.
     */
    nonisolated static func scheduleProgressUpdate(
        sentBytes: Int64,
        totalBytes: Int64
    ) {
        Task { @MainActor in
            RawDeliveryProgress.shared.updateProgress(
                sentBytes: sentBytes,
                totalBytes: totalBytes
            )
        }
    }
}

extension RawDeliveryProgress.Phase {
    /*
     * A 0...1 fraction for a determinate ProgressView, or nil when there is
     * nothing meaningful to show a bar for: still staging (no bytes sent
     * yet), or totalBytes not yet known. That second case covers both
     * URLSession reporting -1 for totalBytesExpectedToSend before it has
     * resolved the request body length, and reattach() seeding a fresh
     * reattachment with 0/0 before the first didSendBodyData callback
     * lands. Clamped because a task can report totalBytesSent fractionally
     * over totalBytesExpectedToSend right at completion.
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
 * rawPhoto set and is skipped. There is deliberately no local retry queue —
 * the server is the record of what still needs doing.
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
         * That transfer is still worth showing progress for, though (#268) —
         * reattachActiveUpload finds it, tags a handler onto it, and hands
         * back the photo id its task was tagged with so the view has
         * something other than "Waiting" for it.
         */
        guard
            await !RawUploadSession.shared
                .hasActiveUploads()
        else {
            if
                RawDeliveryProgress.shared.currentPhotoID
                    == nil,
                let reattachedPhotoID =
                    await RawUploadSession.shared
                    .reattachActiveUpload(
                        onProgress: { sentBytes, totalBytes in
                            RawDeliveryProgress
                                .scheduleProgressUpdate(
                                    sentBytes: sentBytes,
                                    totalBytes: totalBytes
                                )
                        }
                    ),
                photosNeedingRaw.contains(where: { photo in
                    photo.id == reattachedPhotoID
                })
            {
                RawDeliveryProgress.shared.reattach(
                    photoID: reattachedPhotoID,
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
                staged =
                try await Task.detached(
                    priority: .userInitiated
                ) {
                    try RawUploadFileService.stage(
                        photoID: photo.id,
                        filename: photo.originalFilename,
                        reference: reference
                    )
                }
                .value
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
                _ = try await client.uploadRawPhoto(
                    staged,
                    to: photo.id,
                    onProgress: { sentBytes, totalBytes in
                        RawDeliveryProgress
                            .scheduleProgressUpdate(
                                sentBytes: sentBytes,
                                totalBytes: totalBytes
                            )
                    }
                )

                uploadedPhotoCount += 1
                uploadedByteCount += staged.byteSize
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
}
