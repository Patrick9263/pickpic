import Foundation

enum DuplicatePreflightError: LocalizedError {
    case sourceFolderUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceFolderUnavailable:
            return """
            PickPic could not access the event folder to check for \
            duplicates.
            """
        }
    }
}

/*
 * Duplicate preflight.
 *
 * Conversion is by far the most expensive step in the pipeline: decoding
 * and downscaling a Sony RAW costs far more than reading it. Until now
 * PickPic paid that cost for every photo and only learned the event
 * already had it once the upload came back marked as a duplicate.
 *
 * Preflight moves that decision earlier. It asks the event which RAW
 * filenames it already knows, then hashes only those few files locally to
 * confirm. Photos whose filename the event has never seen are skipped
 * entirely by the hashing pass, so a shoot of genuinely new photos costs
 * one small network round trip and no extra file reads.
 *
 * Filenames alone are never sufficient: Sony bodies reset frame counters,
 * so DSC01015.ARW recurs legitimately across cards. Every skip is
 * confirmed by hash.
 *
 * This is an optimisation, not a gate. The worker still performs the
 * authoritative duplicate check on upload, so a preflight failure simply
 * means PickPic converts as it always did.
 */
enum DuplicatePreflightService {
    struct Outcome: Sendable {
        var state: PreflightState
        var hashedFileCount: Int
        var wasCancelled: Bool
    }

    /* Outcome of hashing one candidate file. */
    private struct HashOutcome: Sendable {
        let sourcePhotoID: String
        let sha256: String?
        let isDuplicate: Bool
        let existingPhotoID: String?
    }

    private struct HashPassResult: Sendable {
        var outcomes: [HashOutcome]
        var wasCancelled: Bool
    }

    /* A candidate is a photo whose filename the event already knows. */
    private struct Candidate: Sendable {
        let sourcePhotoID: String
        let filename: String
        let match: PreflightMatch
    }

    static func run(
        job: UploadJob,
        existingState: PreflightState?,
        client: APIClient,
        onProgress: (
            @Sendable (Int, Int) -> Void
        )? = nil
    ) async throws -> Outcome {
        var state = existingState ?? .empty

        state.startedAt =
            state.startedAt ?? Date()
        state.errorMessage = nil

        let photosNeedingCheck =
        job.photos.filter { photo in
            !state.checkedSourcePhotoIDs
                .contains(photo.id)
        }

        guard !photosNeedingCheck.isEmpty else {
            state.checkedAt = Date()

            return Outcome(
                state: state,
                hashedFileCount: 0,
                wasCancelled: false
            )
        }

        let matches =
        try await client.preflightPhotoFilenames(
            photosNeedingCheck.map(\.filename),
            eventID: job.eventID
        )

        /*
         * Filenames are normalised on both sides because the filesystem
         * can hand back decomposed Unicode while the server stored the
         * composed form originally sent.
         */
        var matchesByFilename: [String: PreflightMatch] = [:]

        for match in matches {
            matchesByFilename[
                normalize(match.filename)
            ] = match
        }

        var candidates: [Candidate] = []

        for photo in photosNeedingCheck {
            guard
                let match = matchesByFilename[
                    normalize(photo.filename)
                ]
            else {
                /*
                 * No filename match means the event has never seen this
                 * photo, so no local work is needed at all.
                 */
                state.checkedSourcePhotoIDs
                    .insert(photo.id)

                continue
            }

            /*
             * Photos uploaded before the source-hash migration have no
             * hash to compare against. Surface them, but convert them:
             * skipping on filename alone risks dropping a genuinely new
             * photo, while converting one extra costs only time.
             */
            guard match.hasComparableHash else {
                state.unconfirmedSourcePhotoIDs
                    .insert(photo.id)
                state.existingPhotoIDsBySourcePhotoID[
                    photo.id
                ] = match.photoID
                state.checkedSourcePhotoIDs
                    .insert(photo.id)

                continue
            }

            candidates.append(
                Candidate(
                    sourcePhotoID: photo.id,
                    filename: photo.filename,
                    match: match
                )
            )
        }

        guard !candidates.isEmpty else {
            state.checkedAt = Date()

            return Outcome(
                state: state,
                hashedFileCount: 0,
                wasCancelled: false
            )
        }

        let bookmarkData = job.folderBookmarkData

        /*
         * All file access happens inside a single detached task so the
         * security-scoped resource is never held across a suspension
         * point, matching how conversion isolates its file work.
         *
         * A detached task does not inherit the caller's cancellation, so
         * expireContinuedProcessing cancelling this call's own Task would
         * otherwise never reach the guard inside hashCandidates. Routing
         * the await through withTaskCancellationHandler bridges that:
         * cancelling the caller now explicitly cancels the detached task
         * too.
         */
        let hashingTask = Task.detached(
            priority: .utility
        ) {
            try DuplicatePreflightService.hashCandidates(
                candidates,
                bookmarkData: bookmarkData,
                onProgress: onProgress
            )
        }

        let passResult =
        try await withTaskCancellationHandler {
            try await hashingTask.value
        } onCancel: {
            hashingTask.cancel()
        }

        for outcome in passResult.outcomes {
            if let sha256 = outcome.sha256 {
                state.hashesBySourcePhotoID[
                    outcome.sourcePhotoID
                ] = sha256
            }

            if outcome.isDuplicate {
                state.duplicateSourcePhotoIDs
                    .insert(outcome.sourcePhotoID)
            }

            if let existingPhotoID =
                outcome.existingPhotoID {
                state.existingPhotoIDsBySourcePhotoID[
                    outcome.sourcePhotoID
                ] = existingPhotoID
            }

            state.checkedSourcePhotoIDs
                .insert(outcome.sourcePhotoID)
        }

        /*
         * A cancelled pass keeps whatever it confirmed so the next run
         * resumes instead of rehashing, but is not marked complete.
         */
        if !passResult.wasCancelled {
            state.checkedAt = Date()
        }

        return Outcome(
            state: state,
            hashedFileCount:
                passResult.outcomes.count,
            wasCancelled:
                passResult.wasCancelled
        )
    }

    private static func hashCandidates(
        _ candidates: [Candidate],
        bookmarkData: Data,
        onProgress: (
            @Sendable (Int, Int) -> Void
        )?
    ) throws -> HashPassResult {
        let resolved = try FolderBookmarkService
            .resolve(bookmarkData)

        let folderURL = resolved.url

        guard
            folderURL
                .startAccessingSecurityScopedResource()
        else {
            throw DuplicatePreflightError
                .sourceFolderUnavailable
        }

        defer {
            folderURL
                .stopAccessingSecurityScopedResource()
        }

        var outcomes: [HashOutcome] = []

        for (index, candidate) in candidates.enumerated() {
            guard !Task.isCancelled else {
                return HashPassResult(
                    outcomes: outcomes,
                    wasCancelled: true
                )
            }

            onProgress?(index, candidates.count)

            let photoURL =
            folderURL.appendingPathComponent(
                candidate.filename,
                isDirectory: false
            )

            /*
             * A file that vanished between selection and preflight is not
             * a preflight failure. Mark it checked and leave conversion
             * to report the missing source.
             */
            guard
                FileManager.default.fileExists(
                    atPath: photoURL.path
                )
            else {
                outcomes.append(
                    HashOutcome(
                        sourcePhotoID:
                            candidate.sourcePhotoID,
                        sha256: nil,
                        isDuplicate: false,
                        existingPhotoID: nil
                    )
                )

                continue
            }

            let localSha256 =
            try autoreleasepool {
                try HashingService.sha256Hex(
                    for: photoURL
                )
            }

            let isDuplicate = candidate.match.matches(
                localSha256: localSha256
            )

            outcomes.append(
                HashOutcome(
                    sourcePhotoID:
                        candidate.sourcePhotoID,
                    sha256: localSha256,
                    isDuplicate: isDuplicate,
                    existingPhotoID:
                        isDuplicate
                        ? candidate.match.photoID
                        : nil
                )
            )
        }

        onProgress?(
            candidates.count,
            candidates.count
        )

        return HashPassResult(
            outcomes: outcomes,
            wasCancelled: false
        )
    }

    private static func normalize(
        _ filename: String
    ) -> String {
        filename
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
