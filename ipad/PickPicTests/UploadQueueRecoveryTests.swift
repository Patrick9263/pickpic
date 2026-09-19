import Foundation
import Testing

@testable import PickPic

// Covers the launch-recovery transform extracted by #169 step 2. Every
// expectation here is written against what UploadQueueStore.load() did
// before the extraction -- including the message wording -- because the
// extraction was required to come out behaviour-identical. Treat a
// failure here as "the recovery walk changed", not "the assertion is
// stale".
struct UploadQueueRecoveryTests {
    private static let now = Date(
        timeIntervalSinceReferenceDate: 100_000
    )

    private static func makePhotos(
        _ count: Int
    ) -> [SourcePhoto] {
        (0..<count).map { index in
            SourcePhoto(
                filename: String(
                    format: "DSC%05d.ARW",
                    index + 1
                ),
                byteSize: 50_000_000,
                kind: .raw
            )
        }
    }

    private static func makePreparedPhoto(
        for sourcePhoto: SourcePhoto
    ) -> PreparedPhoto {
        PreparedPhoto(
            sourcePhotoID: sourcePhoto.id,
            sourceFilename: sourcePhoto.filename,
            outputFilename: sourcePhoto.filename
                .replacingOccurrences(
                    of: ".ARW",
                    with: ".jpg"
                ),
            sourceSha256: String(
                repeating: "a",
                count: 64
            ),
            byteSize: 4_000_000,
            pixelWidth: 3_000,
            pixelHeight: 2_000,
            metadata: .empty,
            preparedAt: Date(
                timeIntervalSinceReferenceDate: 500
            )
        )
    }

    private static func makeJob(
        stage: UploadStage,
        photos: [SourcePhoto] = [],
        preparedPhotos: [PreparedPhoto] = [],
        createdAt: Date = Date(
            timeIntervalSinceReferenceDate: 0
        ),
        updatedAt: Date = Date(
            timeIntervalSinceReferenceDate: 1_000
        ),
        conversionCompletedAt: Date? = nil,
        uploadProgress: UploadProgress = .empty,
        continuedProcessing: ContinuedProcessingState? = nil
    ) -> UploadJob {
        UploadJob(
            id: UUID(),
            eventID: "evt-1",
            eventTitle: "Event",
            folderName: "Folder",
            folderBookmarkData: Data([0x01]),
            photos: photos,
            stage: stage,
            createdAt: createdAt,
            updatedAt: updatedAt,
            preparedPhotos: preparedPhotos,
            conversionProcessedCount: preparedPhotos.count,
            conversionCompletedAt: conversionCompletedAt,
            uploadProgress: uploadProgress,
            continuedProcessing: continuedProcessing
        )
    }

    private static func makeContinuedProcessing(
        status: ContinuedProcessingStatus
    ) -> ContinuedProcessingState {
        ContinuedProcessingState(
            identifier: "task-1",
            operation: .prepareConvertAndUpload,
            requestedAt: Date(
                timeIntervalSinceReferenceDate: 900
            ),
            status: status,
            startedAt: Date(
                timeIntervalSinceReferenceDate: 950
            ),
            endedAt: nil,
            message: "Preparing Event"
        )
    }

    // Stands in for ImageConversionService.availablePreparedPhotos, which
    // stats the prepared JPEGs on disk. Returning the job's own list is
    // "every JPEG still there"; returning a prefix is "some went missing".
    private static func keepingAllPreparedPhotos(
        _ job: UploadJob
    ) -> [PreparedPhoto] {
        job.preparedPhotos
    }

    private static func keepingFirstPreparedPhotos(
        _ count: Int
    ) -> (UploadJob) -> [PreparedPhoto] {
        { job in
            Array(job.preparedPhotos.prefix(count))
        }
    }

    @Test
    func interruptedConversionComesBackAsPrepared() throws {
        let photos = Self.makePhotos(3)
        let job = Self.makeJob(
            stage: .converting,
            photos: photos,
            preparedPhotos: photos.prefix(2).map(
                Self.makePreparedPhoto(for:)
            )
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        let recovered = try #require(result.jobs.first)

        #expect(recovered.stage == .prepared)
        #expect(recovered.conversionProcessedCount == 2)
        #expect(recovered.conversionCurrentFilename == nil)
        #expect(recovered.conversionCompletedAt == nil)
        #expect(recovered.updatedAt == Self.now)
        #expect(result.changed)
        #expect(
            result.continuedProcessingJobIDsToCancel.isEmpty
        )
        #expect(
            recovered.conversionErrorMessage
                == """
                Batch conversion was interrupted after 2 of 3 \
                photos. Continue the upload to resume with the \
                remaining photos.
                """
        )
        #expect(
            result.recoveryMessage
                == """
                PickPic restored 1 unfinished upload. Interrupted \
                work was restored. 1 interrupted conversion will \
                resume from saved JPEGs.
                """
        )
    }

    // A conversion that was interrupted before it wrote anything gets the
    // start-again message and does not count toward the resumable total,
    // so the detail sentence is absent.
    @Test
    func conversionInterruptedBeforeAnyJPEGSaysStartAgain() throws {
        let job = Self.makeJob(
            stage: .converting,
            photos: Self.makePhotos(3)
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        let recovered = try #require(result.jobs.first)

        #expect(recovered.stage == .prepared)
        #expect(
            recovered.conversionErrorMessage
                == """
                Batch conversion was interrupted. Start the \
                conversion again.
                """
        )
        #expect(
            result.recoveryMessage
                == """
                PickPic restored 1 unfinished upload. Interrupted \
                work was restored.
                """
        )
    }

    @Test
    func readyToUploadWithMissingJPEGsDemotesAndKeepsUploadedProgress() throws {
        let photos = Self.makePhotos(3)
        var uploadProgress = UploadProgress.empty
        uploadProgress.completedSourceFilenames = [
            "DSC00001.ARW"
        ]
        uploadProgress.currentFilename = "DSC00002.ARW"
        uploadProgress.currentStep = .proofUpload
        uploadProgress.pauseRequested = true

        let job = Self.makeJob(
            stage: .readyToUpload,
            photos: photos,
            preparedPhotos: photos.map(
                Self.makePreparedPhoto(for:)
            ),
            uploadProgress: uploadProgress
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingFirstPreparedPhotos(1)
        )

        let recovered = try #require(result.jobs.first)

        #expect(recovered.stage == .prepared)
        #expect(recovered.preparedPhotos.count == 1)
        #expect(recovered.conversionProcessedCount == 1)
        // The point of the demotion: work already uploaded is not thrown
        // away, only the JPEGs that vanished are recreated.
        #expect(
            recovered.uploadProgress
                .completedSourceFilenames
                == ["DSC00001.ARW"]
        )
        #expect(
            recovered.uploadProgress.currentFilename == nil
        )
        #expect(recovered.uploadProgress.currentStep == nil)
        #expect(
            recovered.uploadProgress.pauseRequested == false
        )
        #expect(
            recovered.conversionErrorMessage
                == """
                PickPic recovered 1 of 3 prepared JPEGs. Continue \
                the upload to recreate only the missing photos. \
                Already-uploaded progress was preserved.
                """
        )
        #expect(
            result.recoveryMessage
                == """
                PickPic restored 1 unfinished upload. Interrupted \
                work was restored. 1 batch will recreate only \
                missing JPEGs.
                """
        )
    }

    // The mirror image: a .prepared batch whose JPEGs are all still there
    // is promoted so the photographer is offered an Upload button rather
    // than a conversion that has already finished.
    @Test
    func preparedBatchWithEveryJPEGIsPromotedToReadyToUpload() throws {
        let photos = Self.makePhotos(2)
        let savedUpdatedAt = Date(
            timeIntervalSinceReferenceDate: 1_000
        )

        let job = Self.makeJob(
            stage: .prepared,
            photos: photos,
            preparedPhotos: photos.map(
                Self.makePreparedPhoto(for:)
            ),
            updatedAt: savedUpdatedAt
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        let recovered = try #require(result.jobs.first)

        #expect(recovered.stage == .readyToUpload)
        #expect(recovered.conversionProcessedCount == 2)
        #expect(recovered.conversionErrorMessage == nil)
        // Read before updatedAt is overwritten with the recovery date, so
        // a batch with no recorded completion inherits its last save.
        #expect(
            recovered.conversionCompletedAt == savedUpdatedAt
        )
        #expect(recovered.updatedAt == Self.now)
        #expect(
            result.recoveryMessage
                == """
                PickPic restored 1 unfinished upload. Interrupted \
                work was restored. 1 completed conversion is ready \
                to upload.
                """
        )
    }

    @Test
    func continuedProcessingOnUnfinishedStagesIsDeferred() throws {
        let jobs = [
            Self.makeJob(
                stage: .queued,
                continuedProcessing:
                    Self.makeContinuedProcessing(
                        status: .active
                    )
            ),
            Self.makeJob(
                stage: .preparing,
                continuedProcessing:
                    Self.makeContinuedProcessing(
                        status: .scheduled
                    )
            ),
            Self.makeJob(
                stage: .failed,
                continuedProcessing:
                    Self.makeContinuedProcessing(
                        status: .active
                    )
            )
        ]

        let result = UploadQueueRecovery.recover(
            jobs: jobs,
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        for recovered in result.jobs {
            let continuedProcessing = try #require(
                recovered.continuedProcessing
            )

            #expect(continuedProcessing.status == .deferred)
            #expect(continuedProcessing.endedAt == Self.now)
            #expect(
                continuedProcessing.message
                    == "The previous iPadOS background-processing task ended. Saved work is ready to resume."
            )
        }

        #expect(
            Set(result.continuedProcessingJobIDsToCancel)
                == Set(jobs.map(\.id))
        )
        #expect(result.changed)
    }

    @Test
    func continuedProcessingOnFinishedStagesIsCleared() {
        let jobs = [
            Self.makeJob(
                stage: .readyToUpload,
                continuedProcessing:
                    Self.makeContinuedProcessing(
                        status: .active
                    )
            ),
            Self.makeJob(
                stage: .uploading,
                continuedProcessing:
                    Self.makeContinuedProcessing(
                        status: .active
                    )
            ),
            Self.makeJob(
                stage: .completed,
                continuedProcessing:
                    Self.makeContinuedProcessing(
                        status: .active
                    )
            )
        ]

        let result = UploadQueueRecovery.recover(
            jobs: jobs,
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        for recovered in result.jobs {
            #expect(recovered.continuedProcessing == nil)
        }

        // Cleared or deferred, the iPadOS task is dead either way and
        // still has to be cancelled -- that is why the ID comes back
        // from both branches.
        #expect(
            Set(result.continuedProcessingJobIDsToCancel)
                == Set(jobs.map(\.id))
        )
        #expect(result.changed)
    }

    // Already-deferred state is left exactly as it was and does not count
    // toward the recovery detail, but the task still needs cancelling.
    @Test
    func alreadyDeferredContinuedProcessingIsLeftAlone() throws {
        let existing = Self.makeContinuedProcessing(
            status: .deferred
        )

        let job = Self.makeJob(
            stage: .queued,
            continuedProcessing: existing
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        let recovered = try #require(result.jobs.first)

        #expect(recovered.continuedProcessing == existing)
        #expect(result.changed == false)
        #expect(
            result.continuedProcessingJobIDsToCancel
                == [job.id]
        )
        #expect(
            result.recoveryMessage
                == """
                PickPic restored 1 unfinished upload. Saved work \
                was restored.
                """
        )
    }

    // Locks in the exact deferred-task sentence, embedded newlines and
    // all. The literal that builds it is the one detail string in the
    // walk written without line continuations, so it renders across
    // three lines where its siblings render as one. That is a real
    // cosmetic defect, reported rather than fixed here because #169
    // requires this extraction to be behaviour-identical.
    @Test
    func deferredContinuedProcessingDetailKeepsItsEmbeddedNewlines() {
        let job = Self.makeJob(
            stage: .queued,
            continuedProcessing:
                Self.makeContinuedProcessing(
                    status: .active
                )
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        #expect(
            result.recoveryMessage
                == "PickPic restored 1 unfinished upload. "
                + "Interrupted work was restored. "
                + "1 continued-processing\ntask\ncan resume from saved progress."
        )
    }

    @Test
    func interruptedUploadWithoutBackgroundTransferReturnsToReadyToUpload() throws {
        let photos = Self.makePhotos(2)
        var uploadProgress = UploadProgress.empty
        uploadProgress.currentRunStartedAt = Date(
            timeIntervalSinceReferenceDate: 600
        )
        uploadProgress.pausedAt = Date(
            timeIntervalSinceReferenceDate: 800
        )
        uploadProgress.currentFilename = "DSC00002.ARW"
        uploadProgress.currentStep = .variantUpload

        let job = Self.makeJob(
            stage: .uploading,
            photos: photos,
            preparedPhotos: photos.map(
                Self.makePreparedPhoto(for:)
            ),
            updatedAt: Date(
                timeIntervalSinceReferenceDate: 1_000
            ),
            uploadProgress: uploadProgress
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        let recovered = try #require(result.jobs.first)

        #expect(recovered.stage == .readyToUpload)
        #expect(recovered.uploadProgress.pausedAt == nil)
        #expect(
            recovered.uploadProgress.currentRunStartedAt == nil
        )
        #expect(
            recovered.uploadProgress.currentFilename == nil
        )
        #expect(recovered.uploadProgress.currentStep == nil)
        #expect(
            recovered.uploadProgress
                .backgroundTransferNeedsReconciliation
                == false
        )
        // The run's active time is banked against the last saved
        // activity, not against the recovery clock -- otherwise every
        // relaunch would charge the upload for time the app spent shut.
        #expect(
            recovered.uploadProgress.activeUploadDuration == 400
        )
        #expect(
            recovered.uploadProgress.errorMessage
                == """
                Uploading was interrupted. Resume the remaining \
                photos.
                """
        )
        #expect(
            result.recoveryMessage
                == """
                PickPic restored 1 unfinished upload. Interrupted \
                work was restored.
                """
        )
    }

    @Test
    func uploadWaitingForConnectivityKeepsItsWaitingMessage() throws {
        let photos = Self.makePhotos(2)
        var uploadProgress = UploadProgress.empty
        uploadProgress.waitingForConnectivitySince = Date(
            timeIntervalSinceReferenceDate: 700
        )

        let job = Self.makeJob(
            stage: .uploading,
            photos: photos,
            preparedPhotos: photos.map(
                Self.makePreparedPhoto(for:)
            ),
            uploadProgress: uploadProgress
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        let recovered = try #require(result.jobs.first)

        #expect(recovered.stage == .readyToUpload)
        #expect(
            recovered.uploadProgress
                .waitingForConnectivitySince
                == Date(
                    timeIntervalSinceReferenceDate: 700
                )
        )
        #expect(
            recovered.uploadProgress.errorMessage
                == """
                PickPic was waiting for an internet connection when \
                it closed. It will retry automatically when a \
                connection is available.
                """
        )
    }

    // An upload iPadOS is still carrying stays .uploading: the transfer
    // outlives the app, so demoting it would re-send bytes already in
    // flight.
    @Test
    func uploadWithLiveBackgroundTransferStaysUploading() throws {
        let photos = Self.makePhotos(2)
        let job = Self.makeJob(
            stage: .uploading,
            photos: photos,
            preparedPhotos: photos.map(
                Self.makePreparedPhoto(for:)
            ),
            uploadProgress: UploadProgress(
                completedSourceFilenames: [],
                duplicateSourceFilenames: [],
                currentFilename: "DSC00002.ARW",
                startedAt: nil,
                completedAt: nil,
                errorMessage: nil,
                activeBackgroundTransfer:
                    BackgroundUploadContext(
                        jobID: UUID(),
                        sourceFilename: "DSC00002.ARW",
                        step: .proofUpload,
                        createdAt: Date(
                            timeIntervalSinceReferenceDate: 800
                        )
                    ),
                backgroundTransferNeedsReconciliation: true
            )
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        let recovered = try #require(result.jobs.first)

        #expect(recovered.stage == .uploading)
        #expect(
            recovered.uploadProgress
                .backgroundTransferNeedsReconciliation
                == false
        )
        #expect(
            recovered.uploadProgress.errorMessage
                == """
                PickPic is reconnecting to an iPadOS background \
                upload. You can continue using other apps.
                """
        )
        #expect(
            result.recoveryMessage
                == """
                PickPic restored 1 unfinished upload. Interrupted \
                work was restored. 1 iPadOS background transfer \
                will be reconnected.
                """
        )
    }

    @Test
    func interruptedPreparationFails() throws {
        let job = Self.makeJob(
            stage: .preparing,
            photos: Self.makePhotos(2)
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        let recovered = try #require(result.jobs.first)

        #expect(recovered.stage == .failed)
        #expect(
            recovered.errorMessage
                == """
                Folder preparation was interrupted. Try the job \
                again.
                """
        )
    }

    @Test
    func interruptedPreflightReturnsToPrepared() throws {
        let photos = Self.makePhotos(2)
        let job = Self.makeJob(
            stage: .preflighting,
            photos: photos,
            preparedPhotos: []
        )

        let result = UploadQueueRecovery.recover(
            jobs: [job],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        let recovered = try #require(result.jobs.first)

        #expect(recovered.stage == .prepared)
        #expect(recovered.updatedAt == Self.now)
    }

    // Trap #1 territory: a queue written before every later UploadJob
    // field existed must survive the recovery walk, not merely decode.
    @Test
    func oldShapeQueueJSONSurvivesRecovery() throws {
        let oldShapeJSON = """
            [{
                "id": "11111111-1111-1111-1111-111111111111",
                "eventID": "evt-1",
                "eventTitle": "Old Event",
                "folderName": "OldFolder",
                "folderBookmarkData": "",
                "photos": [],
                "stage": "converting",
                "createdAt": 0,
                "updatedAt": 0
            }]
            """

        let jobs = try JSONDecoder().decode(
            [UploadJob].self,
            from: Data(oldShapeJSON.utf8)
        )

        let result = UploadQueueRecovery.recover(
            jobs: jobs,
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        let recovered = try #require(result.jobs.first)

        #expect(
            recovered.id.uuidString
                == "11111111-1111-1111-1111-111111111111"
        )
        #expect(recovered.stage == .prepared)
        #expect(recovered.preparedPhotos.isEmpty)
        #expect(recovered.continuedProcessing == nil)
        #expect(recovered.uploadProgress == .empty)
        #expect(
            recovered.conversionErrorMessage
                == """
                Batch conversion was interrupted. Start the \
                conversion again.
                """
        )
    }

    // The "Saved work was restored." branch: nothing was interrupted and
    // no detail applies, so recovery only reports that the queue survived.
    @Test
    func untouchedQueuedJobReportsSavedWorkRestored() {
        let result = UploadQueueRecovery.recover(
            jobs: [Self.makeJob(stage: .queued)],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        #expect(result.changed == false)
        #expect(
            result.recoveryMessage
                == """
                PickPic restored 1 unfinished upload. Saved work \
                was restored.
                """
        )
    }

    @Test
    func multipleUnfinishedJobsPluralizeEveryCount() {
        let photos = Self.makePhotos(3)

        let jobs = (0..<2).map { index in
            Self.makeJob(
                stage: .converting,
                photos: photos,
                preparedPhotos: photos.prefix(1).map(
                    Self.makePreparedPhoto(for:)
                ),
                createdAt: Date(
                    timeIntervalSinceReferenceDate:
                        Double(index)
                )
            )
        }

        let result = UploadQueueRecovery.recover(
            jobs: jobs,
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        #expect(
            result.recoveryMessage
                == """
                PickPic restored 2 unfinished uploads. Interrupted \
                work was restored. 2 interrupted conversions will \
                resume from saved JPEGs.
                """
        )
    }

    @Test
    func allCompletedJobsProduceNoRecoveryMessage() {
        let result = UploadQueueRecovery.recover(
            jobs: [Self.makeJob(stage: .completed)],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        #expect(result.recoveryMessage == nil)
        #expect(result.changed == false)
    }

    @Test
    func recoveredJobsComeBackNewestFirst() {
        let older = Self.makeJob(
            stage: .queued,
            createdAt: Date(
                timeIntervalSinceReferenceDate: 100
            )
        )

        let newer = Self.makeJob(
            stage: .queued,
            createdAt: Date(
                timeIntervalSinceReferenceDate: 200
            )
        )

        let result = UploadQueueRecovery.recover(
            jobs: [older, newer],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        #expect(result.jobs.map(\.id) == [newer.id, older.id])
    }

    @Test
    func emptyQueueRecoversToNothing() {
        let result = UploadQueueRecovery.recover(
            jobs: [],
            now: Self.now,
            availablePreparedPhotos:
                Self.keepingAllPreparedPhotos
        )

        #expect(result.jobs.isEmpty)
        #expect(result.recoveryMessage == nil)
        #expect(result.changed == false)
        #expect(
            result.continuedProcessingJobIDsToCancel.isEmpty
        )
    }
}
