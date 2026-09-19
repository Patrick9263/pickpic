import Foundation

/*
 * What launch recovery decided, handed back as data.
 *
 * The cancellation of iPadOS continued-processing tasks comes back as a
 * list of job IDs rather than being performed here, so this file never
 * imports BackgroundTasks and never reaches a singleton. UploadQueueStore
 * applies the result: assign the jobs, cancel the returned IDs, and
 * rewrite the queue file only when `changed` is true.
 */
struct UploadQueueRecoveryResult: Sendable {
    var jobs: [UploadJob]
    var recoveryMessage: String?
    var changed: Bool
    var continuedProcessingJobIDsToCancel: [UUID]
}

/*
 * The launch-time crash-recovery transform, lifted out of
 * UploadQueueStore.load() so it can be exercised against fixture queue
 * JSON instead of a device that has actually crashed mid-shoot. This is
 * the first code to touch data recovered from an interrupted run, sitting
 * directly on top of UploadJob's hand-written init(from:) -- the place a
 * mistake costs a photographer their in-flight upload state.
 *
 * Deliberately nonisolated and free of I/O. The two things it cannot
 * compute for itself -- the wall clock, and which prepared JPEGs still
 * exist on disk -- are parameters, so a test supplies both.
 *
 * Background-transfer *reconciliation* is a different thing and is not
 * here: that is UploadQueueStore.reconcileBackgroundTransfers(), which
 * talks to a live BackgroundUploadSession. What this transform does with
 * uploadProgress.activeBackgroundTransfer is only decide which stage an
 * interrupted .uploading job comes back in.
 */
enum UploadQueueRecovery {
    static func recover(
        jobs: [UploadJob],
        now: Date,
        availablePreparedPhotos: (UploadJob) -> [PreparedPhoto] =
            ImageConversionService.availablePreparedPhotos(for:)
    ) -> UploadQueueRecoveryResult {
        var decodedJobs = jobs

        var changedRecoveredState = false
        var interruptedJobCount = 0
        var resumedConversionJobCount = 0
        var unavailablePreparedBatchCount = 0
        var fullyRecoveredBatchCount = 0
        var restoredBackgroundTransferCount = 0
        var deferredContinuedProcessingCount = 0
        var continuedProcessingJobIDsToCancel: [UUID] = []
        let recoveryDate = now

        for index in decodedJobs.indices {
            let originalStage =
                decodedJobs[index].stage

            if var continuedProcessing =
                decodedJobs[index].continuedProcessing
            {
                continuedProcessingJobIDsToCancel.append(
                    decodedJobs[index].id
                )

                switch originalStage {
                case .readyToUpload,
                        .uploading,
                        .completed:
                    decodedJobs[index]
                        .continuedProcessing = nil
                    changedRecoveredState = true

                case .queued,
                        .preparing,
                        .prepared,
                        .preflighting,
                        .converting,
                        .failed:
                    if continuedProcessing.status
                        != .deferred
                    {
                        continuedProcessing.status =
                            .deferred
                        continuedProcessing.endedAt =
                            recoveryDate
                        continuedProcessing.message =
                            "The previous iPadOS background-processing task ended. Saved work is ready to resume."
                        decodedJobs[index]
                            .continuedProcessing =
                                continuedProcessing
                        changedRecoveredState = true
                        deferredContinuedProcessingCount += 1
                    }
                }
            }

            switch originalStage {
            case .prepared,
                    .preflighting,
                    .converting,
                    .readyToUpload,
                    .uploading:
                let recoveredPreparedPhotos =
                availablePreparedPhotos(
                    decodedJobs[index]
                )

                if recoveredPreparedPhotos
                    != decodedJobs[index]
                        .preparedPhotos
                {
                    decodedJobs[index]
                        .preparedPhotos =
                            recoveredPreparedPhotos
                    decodedJobs[index]
                        .conversionProcessedCount =
                            recoveredPreparedPhotos.count
                    changedRecoveredState = true
                }

            case .queued,
                    .preparing,
                    .completed,
                    .failed:
                break
            }

            switch originalStage {
            case .preparing:
                decodedJobs[index].stage = .failed
                decodedJobs[index].errorMessage =
                    """
                    Folder preparation was interrupted. \
                    Try the job again.
                    """
                decodedJobs[index].updatedAt =
                    recoveryDate
                changedRecoveredState = true
                interruptedJobCount += 1

            case .preflighting:
                /*
                 * Preflight is cheap and restartable, and any hashes
                 * it already computed are persisted, so returning to
                 * .prepared resumes rather than restarts the work.
                 */
                decodedJobs[index].stage = .prepared
                decodedJobs[index].updatedAt =
                    recoveryDate
                changedRecoveredState = true

            case .converting:
                let recoveredCount =
                    decodedJobs[index]
                        .preparedPhotos.count

                decodedJobs[index].stage = .prepared
                decodedJobs[index]
                    .conversionProcessedCount =
                        recoveredCount
                decodedJobs[index]
                    .conversionCurrentFilename = nil
                decodedJobs[index]
                    .conversionCompletedAt = nil

                if recoveredCount > 0 {
                    decodedJobs[index]
                        .conversionErrorMessage =
                        """
                        Batch conversion was interrupted after \
                        \(recoveredCount) of \
                        \(decodedJobs[index].photoCount) photos. \
                        Continue the upload to resume with the \
                        remaining photos.
                        """
                    if recoveredCount
                        < decodedJobs[index].photoCount
                    {
                        resumedConversionJobCount += 1
                    }
                } else {
                    decodedJobs[index]
                        .conversionErrorMessage =
                        """
                        Batch conversion was interrupted. \
                        Start the conversion again.
                        """
                }

                decodedJobs[index].updatedAt =
                    recoveryDate
                changedRecoveredState = true
                interruptedJobCount += 1

            case .uploading:
                let wasWaitingForConnectivity =
                    decodedJobs[index]
                        .uploadProgress
                        .isWaitingForConnectivity

                if let currentRunStartedAt =
                    decodedJobs[index]
                        .uploadProgress
                        .currentRunStartedAt
                {
                    let lastSavedActivityDate = max(
                        decodedJobs[index].updatedAt,
                        currentRunStartedAt
                    )

                    stopActiveUploadTimer(
                        &decodedJobs[index]
                            .uploadProgress,
                        at: lastSavedActivityDate
                    )
                }

                decodedJobs[index]
                    .uploadProgress
                    .pausedAt = nil
                decodedJobs[index]
                    .uploadProgress
                    .currentRunStartedAt = nil

                if decodedJobs[index]
                    .uploadProgress
                    .activeBackgroundTransfer != nil
                {
                    decodedJobs[index].stage =
                        .uploading
                    decodedJobs[index]
                        .uploadProgress
                        .errorMessage =
                        wasWaitingForConnectivity
                        ? """
                        PickPic restored a background upload that was \
                        waiting for connectivity. iPadOS will continue \
                        it when a connection is available.
                        """
                        : """
                        PickPic is reconnecting to an iPadOS background \
                        upload. You can continue using other apps.
                        """
                    decodedJobs[index]
                        .uploadProgress
                        .backgroundTransferNeedsReconciliation =
                            false
                    restoredBackgroundTransferCount += 1
                } else {
                    decodedJobs[index]
                        .uploadProgress
                        .pauseRequested = false
                    decodedJobs[index].stage =
                        .readyToUpload
                    decodedJobs[index]
                        .uploadProgress
                        .currentFilename = nil
                    decodedJobs[index]
                        .uploadProgress
                        .currentStep = nil
                    decodedJobs[index]
                        .uploadProgress
                        .errorMessage =
                        wasWaitingForConnectivity
                        ? """
                        PickPic was waiting for an internet connection \
                        when it closed. It will retry automatically when \
                        a connection is available.
                        """
                        : """
                        Uploading was interrupted. \
                        Resume the remaining photos.
                        """
                    decodedJobs[index]
                        .uploadProgress
                        .backgroundTransferNeedsReconciliation =
                            false

                    if !wasWaitingForConnectivity {
                        decodedJobs[index]
                            .uploadProgress
                            .waitingForConnectivitySince = nil
                    }

                    interruptedJobCount += 1
                }

                decodedJobs[index].updatedAt =
                    recoveryDate
                changedRecoveredState = true

            case .queued,
                    .prepared,
                    .readyToUpload,
                    .completed,
                    .failed:
                break
            }

            if
                decodedJobs[index].stage
                    == .readyToUpload,
                decodedJobs[index].preparedPhotos
                    .count
                    != decodedJobs[index]
                        .expectedPreparedPhotoCount
            {
                let recoveredCount =
                    decodedJobs[index]
                        .preparedPhotos.count

                decodedJobs[index].stage = .prepared
                decodedJobs[index]
                    .conversionProcessedCount =
                        recoveredCount
                decodedJobs[index]
                    .conversionCurrentFilename = nil
                decodedJobs[index]
                    .conversionCompletedAt = nil
                decodedJobs[index]
                    .conversionErrorMessage =
                    """
                    PickPic recovered \(recoveredCount) of \
                    \(decodedJobs[index].photoCount) prepared JPEGs. \
                    Continue the upload to recreate only the \
                    missing photos. Already-uploaded progress was \
                    preserved.
                    """
                decodedJobs[index]
                    .uploadProgress
                    .currentFilename = nil
                decodedJobs[index]
                    .uploadProgress
                    .currentStep = nil
                decodedJobs[index]
                    .uploadProgress
                    .pauseRequested = false
                decodedJobs[index]
                    .uploadProgress
                    .currentRunStartedAt = nil
                decodedJobs[index]
                    .uploadProgress
                    .waitingForConnectivitySince = nil
                decodedJobs[index].updatedAt =
                    recoveryDate
                changedRecoveredState = true
                unavailablePreparedBatchCount += 1
            } else if
                decodedJobs[index].stage == .prepared,
                decodedJobs[index].photoCount > 0,
                /*
                 * A batch whose every frame was skipped has nothing
                 * to upload, and promoting it would offer an Upload
                 * button that can only report an incomplete batch.
                 */
                decodedJobs[index]
                    .expectedPreparedPhotoCount > 0,
                decodedJobs[index].preparedPhotos
                    .count
                    == decodedJobs[index]
                        .expectedPreparedPhotoCount
            {
                decodedJobs[index].stage =
                    .readyToUpload
                decodedJobs[index]
                    .conversionProcessedCount =
                        decodedJobs[index]
                            .preparedPhotos.count
                decodedJobs[index]
                    .conversionCurrentFilename = nil
                decodedJobs[index]
                    .conversionCompletedAt =
                        decodedJobs[index]
                            .conversionCompletedAt
                        ?? decodedJobs[index]
                            .updatedAt
                decodedJobs[index]
                    .conversionErrorMessage = nil
                decodedJobs[index].updatedAt =
                    recoveryDate
                changedRecoveredState = true
                fullyRecoveredBatchCount += 1
            }
        }

        decodedJobs.sort { first, second in
            first.createdAt > second.createdAt
        }

        let unfinishedJobCount = decodedJobs.filter { job in
            job.stage != .completed
        }
        .count

        var recoveryDetails: [String] = []

        if resumedConversionJobCount > 0 {
            recoveryDetails.append(
                """
                \(resumedConversionJobCount) interrupted \
                conversion\(resumedConversionJobCount == 1 ? "" : "s") \
                will resume from saved JPEGs.
                """
            )
        }

        if restoredBackgroundTransferCount > 0 {
            recoveryDetails.append(
                """
                \(restoredBackgroundTransferCount) iPadOS background \
                transfer\(restoredBackgroundTransferCount == 1 ? "" : "s") \
                will be reconnected.
                """
            )
        }

        if deferredContinuedProcessingCount > 0 {
            recoveryDetails.append(
                """
                \(deferredContinuedProcessingCount) continued-processing \
                task\(deferredContinuedProcessingCount == 1 ? "" : "s") \
                can resume from saved progress.
                """
            )
        }

        if unavailablePreparedBatchCount > 0 {
            recoveryDetails.append(
                """
                \(unavailablePreparedBatchCount) \
                batch\(unavailablePreparedBatchCount == 1 ? "" : "es") \
                will recreate only missing JPEGs.
                """
            )
        }

        if fullyRecoveredBatchCount > 0 {
            recoveryDetails.append(
                """
                \(fullyRecoveredBatchCount) completed \
                conversion\(fullyRecoveredBatchCount == 1 ? "" : "s") \
                \(fullyRecoveredBatchCount == 1 ? "is" : "are") ready to upload.
                """
            )
        }

        let recoveryMessage: String?

        if unfinishedJobCount > 0 {
            let baseMessage: String

            if interruptedJobCount > 0
                || !recoveryDetails.isEmpty
            {
                baseMessage =
                    "Interrupted work was restored."
            } else {
                baseMessage =
                    "Saved work was restored."
            }

            recoveryMessage = ([
                """
                PickPic restored \(unfinishedJobCount) unfinished \
                upload\(unfinishedJobCount == 1 ? "" : "s").
                """,
                baseMessage
            ] + recoveryDetails)
            .joined(separator: " ")
        } else {
            recoveryMessage = nil
        }

        return UploadQueueRecoveryResult(
            jobs: decodedJobs,
            recoveryMessage: recoveryMessage,
            changed: changedRecoveredState,
            continuedProcessingJobIDsToCancel:
                continuedProcessingJobIDsToCancel
        )
    }

    /*
     * Lives here rather than on UploadQueueStore so the recovery walk
     * stays clear of the @MainActor store. UploadQueueStore's own
     * stopActiveUploadTimer forwards to this, keeping one implementation
     * of the active-upload-time accounting its upload paths share.
     */
    static func stopActiveUploadTimer(
        _ progress: inout UploadProgress,
        at stoppedAt: Date
    ) {
        guard let runStartedAt =
            progress.currentRunStartedAt
        else {
            return
        }

        progress.activeUploadDuration += max(
            stoppedAt.timeIntervalSince(
                runStartedAt
            ),
            0
        )

        progress.currentRunStartedAt = nil
    }
}
