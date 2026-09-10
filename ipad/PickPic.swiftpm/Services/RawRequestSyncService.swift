import Foundation

struct RawRequestSyncResult: Sendable {
    let uploadedPhotoCount: Int
    let uploadedByteCount: Int64
    let missingFilenames: [String]
    let failures: [String]
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

        /*
         * A relaunch can land while iPadOS is still finishing a transfer the
         * previous process started. That upload has not reached the server
         * yet, so its request still reads as pending — staging and sending it
         * again would push the same RAW twice.
         */
        guard
            await !RawUploadSession.shared
                .hasActiveUploads()
        else {
            return nil
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
            return nil
        }

        var uploadedPhotoCount = 0
        var uploadedByteCount: Int64 = 0
        var missingFilenames: [String] = []
        var failures: [String] = []

        for photo in photosNeedingRaw {
            guard !Task.isCancelled else {
                break
            }

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
                continue
            } catch {
                failures.append(
                    photo.originalFilename
                )

                continue
            }

            do {
                _ = try await client.uploadRawPhoto(
                    staged,
                    to: photo.id
                )

                uploadedPhotoCount += 1
                uploadedByteCount += staged.byteSize
            } catch {
                failures.append(
                    photo.originalFilename
                )
            }

            /*
             * Removed whether or not the upload succeeded: a retry re-stages
             * from the event folder, and these are the largest files the app
             * ever writes into its own container.
             */
            try? RawUploadFileService.removeStagedFile(
                photoID: photo.id
            )
        }

        return RawRequestSyncResult(
            uploadedPhotoCount: uploadedPhotoCount,
            uploadedByteCount: uploadedByteCount,
            missingFilenames: missingFilenames,
            failures: failures
        )
    }
}
