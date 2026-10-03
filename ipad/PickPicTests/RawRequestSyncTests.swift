import Foundation
import Testing

@testable import PickPic

struct ServerPhotoRecordRawRequestTests {
    // The shape listPhotos sent before #205 -- and the shape createPhoto's
    // 201 body still sends, since it is built from a plain PhotoRecord that
    // carries no RAW fields at all. Both new fields must decode from their
    // absence rather than taking the whole photo list down with them
    // (CLAUDE.md trap #1).
    private static let withoutRawFieldsJSON = """
        {
            "id": "photo-1",
            "originalFilename": "DSC01015.ARW",
            "heartCount": 0,
            "workflowStatus": "idle",
            "variants": {},
            "finalPhoto": null,
            "capturedAt": null
        }
        """

    private static func json(
        pendingRawRequestCount: Int,
        hasRawPhoto: Bool
    ) -> String {
        let rawPhoto =
        hasRawPhoto
        ? """
        {
            "originalFilename": "DSC01015.ARW",
            "byteSize": 74000000,
            "uploadedAt": "2026-09-09T00:00:00.000Z"
        }
        """
        : "null"

        return """
            {
                "id": "photo-1",
                "originalFilename": "DSC01015.ARW",
                "heartCount": 0,
                "workflowStatus": "idle",
                "variants": {},
                "finalPhoto": null,
                "capturedAt": null,
                "pendingRawRequestCount": \(pendingRawRequestCount),
                "rawPhoto": \(rawPhoto)
            }
            """
    }

    private static func decode(
        _ json: String
    ) throws -> ServerPhotoRecord {
        try JSONDecoder().decode(
            ServerPhotoRecord.self,
            from: Data(json.utf8)
        )
    }

    @Test
    func aResponseWithoutTheRawFieldsStillDecodes() throws {
        let photo = try Self.decode(
            Self.withoutRawFieldsJSON
        )

        #expect(photo.pendingRawRequestCount == nil)
        #expect(photo.pendingRawRequests == 0)
        #expect(photo.rawPhoto == nil)
        #expect(photo.needsRawUpload == false)
    }

    @Test
    func aPendingRequestWithNoDeliveredRawNeedsUpload() throws {
        let photo = try Self.decode(
            Self.json(
                pendingRawRequestCount: 2,
                hasRawPhoto: false
            )
        )

        #expect(photo.pendingRawRequests == 2)
        #expect(photo.needsRawUpload)
    }

    // The case that matters most: a visitor can request a RAW that has
    // already been delivered, which leaves a pending row against a photo
    // whose original is in R2 already. Without the rawPhoto half of the
    // test the iPad would resend the same file on every activation sweep.
    @Test
    func aPendingRequestForAnAlreadyDeliveredRawDoesNot() throws {
        let photo = try Self.decode(
            Self.json(
                pendingRawRequestCount: 1,
                hasRawPhoto: true
            )
        )

        #expect(photo.rawPhoto != nil)
        #expect(photo.needsRawUpload == false)
    }

    @Test
    func noPendingRequestsNeverNeedsUpload() throws {
        for hasRawPhoto in [true, false] {
            let photo = try Self.decode(
                Self.json(
                    pendingRawRequestCount: 0,
                    hasRawPhoto: hasRawPhoto
                )
            )

            #expect(photo.needsRawUpload == false)
        }
    }
}

// #267: pendingRawRequestCount is summed into EventPhotoStatistics the same
// way likedPhotoCount etc. already are, so the overview grid and per-event
// row can surface it without any new server plumbing.
struct EventPhotoStatisticsPendingRawRequestTests {
    private static func photo(
        pendingRawRequestCount: Int
    ) throws -> ServerPhotoRecord {
        let json = """
            {
                "id": "photo-\(pendingRawRequestCount)-\(UUID().uuidString)",
                "originalFilename": "DSC01015.ARW",
                "heartCount": 0,
                "workflowStatus": "idle",
                "variants": {},
                "finalPhoto": null,
                "capturedAt": null,
                "pendingRawRequestCount": \(pendingRawRequestCount),
                "rawPhoto": null
            }
            """

        return try JSONDecoder().decode(
            ServerPhotoRecord.self,
            from: Data(json.utf8)
        )
    }

    private static func event(
        id: String
    ) -> PickPicEvent {
        PickPicEvent(
            id: id,
            title: id,
            shareToken: id,
            status: .ready,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    @Test
    func sumsPendingRawRequestsAcrossPhotosInAnEvent() throws {
        let photos = try [
            Self.photo(pendingRawRequestCount: 2),
            Self.photo(pendingRawRequestCount: 0),
            Self.photo(pendingRawRequestCount: 1)
        ]

        let statistics = EventPhotoStatistics(
            photos: photos
        )

        #expect(statistics.pendingRawRequestCount == 3)
    }

    @Test
    func totalSumsAcrossEventsAndSkipsUnloadedOnes() throws {
        let loadedEvent = Self.event(id: "event-1")
        let unloadedEvent = Self.event(id: "event-2")

        let statistics = EventPhotoStatistics(
            photos: try [
                Self.photo(pendingRawRequestCount: 3),
                Self.photo(pendingRawRequestCount: 1)
            ]
        )

        let total = EventPhotoStatistics.total(
            for: [loadedEvent, unloadedEvent],
            statisticsByEventID: [
                loadedEvent.id: statistics
            ]
        )

        #expect(total.pendingRawRequestCount == 4)
    }
}

// RawDeliveryProgress itself is @MainActor and only ever mutated from
// RawRequestSyncService's sync loop, so it isn't exercised directly here --
// see the note on UploadQueueStore's own untestability in CLAUDE.md for why
// that kind of state-machine glue stays out of this target. fractionCompleted
// is the pure piece pulled out of it (#268): what a progress bar should show
// for a given phase, including the edge cases URLSession and a relaunch
// reattachment can both produce.
struct RawDeliveryProgressPhaseTests {
    @Test
    func stagingHasNoFraction() {
        let phase = RawDeliveryProgress.Phase.staging

        #expect(phase.fractionCompleted == nil)
    }

    // URLSession reports totalBytesExpectedToSend == -1 until it has
    // resolved the request body length, and reattachActiveUpload seeds a
    // fresh reattachment with 0/0 before the first didSendBodyData callback
    // lands. Neither should render as "0% complete".
    @Test
    func unknownTotalHasNoFraction() {
        for totalBytes: Int64 in [0, -1] {
            let phase = RawDeliveryProgress.Phase.uploading(
                sentBytes: 0,
                totalBytes: totalBytes
            )

            #expect(phase.fractionCompleted == nil)
        }
    }

    @Test
    func computesAFractionOnceTotalsAreKnown() {
        let phase = RawDeliveryProgress.Phase.uploading(
            sentBytes: 25_000_000,
            totalBytes: 100_000_000
        )

        #expect(phase.fractionCompleted == 0.25)
    }

    // A task can report totalBytesSent fractionally over
    // totalBytesExpectedToSend right at completion; the bar must not
    // overshoot 1.0.
    @Test
    func clampsAFractionOverOne() {
        let phase = RawDeliveryProgress.Phase.uploading(
            sentBytes: 100_000_001,
            totalBytes: 100_000_000
        )

        #expect(phase.fractionCompleted == 1)
    }
}

struct RawUploadFileServiceValidationTests {
    @Test
    func acceptsAPlainFilename() throws {
        try RawUploadFileService.validate(
            filename: "DSC01015.ARW",
            byteSize: 74_000_000
        )
    }

    // The filename comes from the server, so a path in it would let a
    // response reach outside the event folder.
    @Test
    func rejectsFilenamesThatAreNotASinglePathComponent() {
        for filename in [
            "",
            ".",
            "..",
            "../DSC01015.ARW",
            "To Edit/DSC01015.ARW"
        ] {
            #expect(
                !RawUploadFileService
                    .isSafePathComponent(filename)
            )

            #expect(throws: RawUploadFileError.self) {
                try RawUploadFileService.validate(
                    filename: filename,
                    byteSize: 1_024
                )
            }
        }
    }

    @Test
    func rejectsAFileOverTheLimit() {
        #expect(throws: RawUploadFileError.self) {
            try RawUploadFileService.validate(
                filename: "DSC01015.ARW",
                byteSize: RawUploadFileService
                    .maximumRawBytes + 1
            )
        }
    }

    // Boundary, not an off-by-one: the worker's own check is
    // `> MAX_RAW_BYTES`, so exactly the limit has to pass on both sides or
    // the app rejects a file the server would have taken.
    @Test
    func acceptsAFileExactlyAtTheLimit() throws {
        try RawUploadFileService.validate(
            filename: "DSC01015.ARW",
            byteSize: RawUploadFileService
                .maximumRawBytes
        )
    }

    @Test
    func matchesTheWorkersOwnLimit() {
        #expect(
            RawUploadFileService.maximumRawBytes
            == 100 * 1_024 * 1_024
        )
    }
}

// #368: the part layout has to agree byte-for-byte with the worker's
// rawUploadPartCount and expectedSize, which reject any part of another
// length.
struct RawUploadPartPlanTests {
    private static let mebibyte: Int64 = 1_024 * 1_024

    @Test func splitsARawIntoFullPartsAndAShorterLastOne() {
        let plan = RawUploadPartPlan(
            byteSize: 75 * Self.mebibyte + 123,
            partSize: 8 * Self.mebibyte
        )

        #expect(plan.partCount == 10)
        #expect(plan.size(ofPart: 1) == 8 * Self.mebibyte)
        #expect(plan.size(ofPart: 9) == 8 * Self.mebibyte)
        #expect(plan.size(ofPart: 10) == 3 * Self.mebibyte + 123)
    }

    @Test func anExactMultipleHasNoShortLastPart() {
        let plan = RawUploadPartPlan(byteSize: 24, partSize: 8)

        #expect(plan.partCount == 3)
        #expect(plan.size(ofPart: 3) == 8)
    }

    @Test func aFileSmallerThanOnePartIsOnePart() {
        let plan = RawUploadPartPlan(byteSize: 5, partSize: 8)

        #expect(plan.partCount == 1)
        #expect(plan.byteRange(ofPart: 1) == 0..<5)
    }

    @Test func byteRangesAreContiguousAndCoverTheFile() {
        let plan = RawUploadPartPlan(byteSize: 20, partSize: 8)

        #expect(plan.byteRange(ofPart: 1) == 0..<8)
        #expect(plan.byteRange(ofPart: 2) == 8..<16)
        #expect(plan.byteRange(ofPart: 3) == 16..<20)
    }

    @Test func partsOutsideThePlanHaveNoRange() {
        let plan = RawUploadPartPlan(byteSize: 20, partSize: 8)
        let empty = RawUploadPartPlan(byteSize: 0, partSize: 8)

        #expect(plan.byteRange(ofPart: 0) == nil)
        #expect(plan.byteRange(ofPart: 4) == nil)
        #expect(empty.partCount == 0)
        #expect(empty.byteRange(ofPart: 1) == nil)
        #expect(empty.partsToSend(landedParts: []).isEmpty)
    }

    @Test func sendsOnlyTheMissingParts() {
        let plan = RawUploadPartPlan(byteSize: 40, partSize: 8)

        #expect(plan.partsToSend(landedParts: []) == [1, 2, 3, 4, 5])
        #expect(plan.partsToSend(landedParts: [1, 3, 5]) == [2, 4])
        // Out-of-plan numbers from the server are ignored, not trusted.
        #expect(plan.partsToSend(landedParts: [2, 9, -1]) == [1, 3, 4, 5])
    }

    // Every part landed but the photo still wants its RAW: the server's
    // completion failed and released its claim, so the last part is re-sent
    // to trigger it again.
    @Test func resendsTheLastPartWhenNothingIsMissing() {
        let plan = RawUploadPartPlan(byteSize: 40, partSize: 8)

        #expect(plan.partsToSend(landedParts: [1, 2, 3, 4, 5]) == [5])
    }
}

struct RawUploadProgressTallyTests {
    private static let plan = RawUploadPartPlan(byteSize: 20, partSize: 8)

    @Test func countsLandedPartsAndInFlightBytes() {
        var tally = RawUploadProgressTally(
            plan: Self.plan,
            landedParts: [1]
        )

        #expect(tally.sentBytes == 8)
        #expect(tally.totalBytes == 20)

        // A first sample of 0 sets an identity baseline, so later counts
        // read at face value.
        tally.recordSent(0, forPart: 2)
        tally.recordSent(3, forPart: 2)
        #expect(tally.sentBytes == 11)

        tally.markLanded(2)
        #expect(tally.sentBytes == 16)

        tally.recordSent(4, forPart: 3)
        tally.markLanded(3)
        #expect(tally.sentBytes == 20)
    }

    @Test func aFailedPartStartsItsCountAgain() {
        var tally = RawUploadProgressTally(
            plan: Self.plan,
            landedParts: []
        )

        tally.recordSent(6, forPart: 1)
        tally.markFailed(1)

        #expect(tally.sentBytes == 0)
    }

    @Test func clampsOverreportedAndIgnoresUnknownParts() {
        var tally = RawUploadProgressTally(
            plan: Self.plan,
            landedParts: [7]
        )

        // A part past its own size (URLSession at completion) and a part
        // outside the plan must never push the total past the file.
        tally.recordSent(100, forPart: 3)
        tally.recordSent(100, forPart: 9)

        #expect(tally.landedParts.isEmpty)
        #expect(tally.sentBytes == 4)
    }

    @Test func sentBytesForALandedPartAreNotCountedTwice() {
        var tally = RawUploadProgressTally(
            plan: Self.plan,
            landedParts: [1]
        )

        tally.recordSent(8, forPart: 1)

        #expect(tally.sentBytes == 8)
    }

    // #374: every part's first didSendBodyData reported exactly 2 MiB
    // within 0.18 s -- the send buffer filling, not the network. That first
    // sample must not move the bar.
    @Test func aPartsFirstBufferedSampleDoesNotJumpTheBar() {
        var tally = RawUploadProgressTally(
            plan: Self.plan,
            landedParts: []
        )

        tally.recordSent(2, forPart: 1)
        tally.recordSent(2, forPart: 2)

        #expect(tally.sentBytes == 0)
    }

    @Test func aBaselinedPartStillReachesFullSizeOnItsLastByte() {
        var tally = RawUploadProgressTally(
            plan: Self.plan,
            landedParts: []
        )

        tally.recordSent(2, forPart: 1)
        tally.recordSent(5, forPart: 1)
        // (5 - 2) * 8 / (8 - 2)
        #expect(tally.sentBytes == 4)

        tally.recordSent(8, forPart: 1)
        #expect(tally.sentBytes == 8)

        tally.markLanded(1)
        #expect(tally.sentBytes == 8)
        #expect(tally.inFlightBaselines.isEmpty)
    }

    // The small last part is buffered whole on its first sample; rescaling
    // it would only move the jump to its end, so it counts as before.
    @Test func aFullyBufferedSmallPartCountsAtFaceValue() {
        var tally = RawUploadProgressTally(
            plan: Self.plan,
            landedParts: []
        )

        tally.recordSent(4, forPart: 3)

        #expect(tally.sentBytes == 4)
        #expect(tally.inFlightBaselines.isEmpty)
    }

    // A retry re-fills the send buffer, so its baseline is taken afresh.
    @Test func aFailedPartTakesANewBaselineOnRetry() {
        var tally = RawUploadProgressTally(
            plan: Self.plan,
            landedParts: []
        )

        tally.recordSent(2, forPart: 1)
        tally.recordSent(5, forPart: 1)
        tally.markFailed(1)

        #expect(tally.sentBytes == 0)
        #expect(tally.inFlightBaselines.isEmpty)

        tally.recordSent(3, forPart: 1)
        #expect(tally.sentBytes == 0)

        tally.recordSent(8, forPart: 1)
        #expect(tally.sentBytes == 8)
    }

    // After a relaunch, reattach builds a fresh tally and a running part's
    // first sample lands mid-part. It becomes the baseline, so the part
    // reads 0 -- as it did before the sample -- rather than going backwards.
    @Test func aReattachedPartsMidwaySampleNeverMovesTheBarBackwards() {
        var tally = RawUploadProgressTally(
            plan: Self.plan,
            landedParts: [1]
        )

        #expect(tally.sentBytes == 8)

        tally.recordSent(5, forPart: 2)
        #expect(tally.sentBytes == 8)

        tally.recordSent(8, forPart: 2)
        #expect(tally.sentBytes == 16)
    }

    // The shape measured on device: a 77 MB ARW in 10 parts, every part
    // first reporting 2 MiB at once, then advancing one at a time in 1 MiB
    // steps, with an over-reported count at each part's completion.
    @Test func sentBytesNeverDecreasesNorExceedsTheFile() {
        let mebibyte: Int64 = 1_024 * 1_024
        let plan = RawUploadPartPlan(
            byteSize: 77_000_000,
            partSize: RawUploadPartPlan.defaultPartSize
        )
        var tally = RawUploadProgressTally(plan: plan, landedParts: [])
        var previous = tally.sentBytes

        func check() {
            let sent = tally.sentBytes
            #expect(sent >= previous)
            #expect(sent <= plan.byteSize)
            previous = sent
        }

        let parts = plan.partNumbers.map(Array.init) ?? []
        #expect(parts.count == 10)

        for partNumber in parts {
            tally.recordSent(2 * mebibyte, forPart: partNumber)
            check()
        }

        #expect(tally.sentBytes == plan.size(ofPart: 10))

        for partNumber in parts {
            let partSize = plan.size(ofPart: partNumber) ?? 0
            var sent = 2 * mebibyte

            while sent < partSize {
                sent = min(sent + mebibyte, partSize)
                tally.recordSent(sent, forPart: partNumber)
                check()
            }

            tally.recordSent(partSize + 100, forPart: partNumber)
            check()

            tally.markLanded(partNumber)
            check()
        }

        #expect(tally.sentBytes == plan.byteSize)
    }
}

struct RawPartTaskTagTests {
    @Test func roundTripsThroughTaskDescription() {
        let tag = RawPartTaskTag(
            photoID: "photo-1",
            partNumber: 3,
            byteSize: 20,
            partSize: 8
        )

        #expect(
            RawPartTaskTag(taskDescription: tag.taskDescription) == tag
        )
        #expect(tag.plan.partCount == 3)
    }

    // An older build tagged its single-request upload with the bare photo
    // id; that must read as "not a part", not crash or misattribute.
    @Test func rejectsABarePhotoIDAndImpossibleParts() {
        #expect(RawPartTaskTag(taskDescription: "photo-1") == nil)

        let outOfPlan = RawPartTaskTag(
            photoID: "photo-1",
            partNumber: 4,
            byteSize: 20,
            partSize: 8
        )

        #expect(
            RawPartTaskTag(taskDescription: outOfPlan.taskDescription)
                == nil
        )

        #expect(
            RawPartTaskTag(
                taskDescription:
                    #"{"photoID":"p","partNumber":1,"byteSize":20,"partSize":0}"#
            ) == nil
        )
    }
}

struct RawPartRetryPolicyTests {
    @Test func backsOffThenGivesUp() {
        #expect(RawPartRetryPolicy.delay(afterAttempt: 1) == .seconds(2))
        #expect(RawPartRetryPolicy.delay(afterAttempt: 4) == .seconds(16))
        #expect(
            RawPartRetryPolicy.delay(
                afterAttempt: RawPartRetryPolicy.maximumAttempts
            ) == nil
        )
    }

    @Test func retriesTransientFailuresOnly() {
        #expect(
            RawPartRetryPolicy.isRetryable(
                URLError(.networkConnectionLost)
            )
        )
        #expect(!RawPartRetryPolicy.isRetryable(URLError(.cancelled)))

        for statusCode in [408, 429, 500, 503] {
            #expect(
                RawPartRetryPolicy.isRetryable(
                    APIClientError.server(
                        statusCode: statusCode,
                        message: ""
                    )
                )
            )
        }

        // A wrong-size part, the storage cap, a session start has replaced.
        for statusCode in [400, 403, 404] {
            #expect(
                !RawPartRetryPolicy.isRetryable(
                    APIClientError.server(
                        statusCode: statusCode,
                        message: ""
                    )
                )
            )
        }

        #expect(
            !RawPartRetryPolicy.isRetryable(
                APIClientError.unauthorized(message: "")
            )
        )
    }
}

// #373: RawRequestsView's Pending and Delivered lists.
struct RawRequestListTests {
    private static func photo(
        filename: String,
        pendingRawRequestCount: Int,
        rawUploadedAt: String?
    ) throws -> ServerPhotoRecord {
        let rawPhoto =
        rawUploadedAt.map { uploadedAt in
            """
            {
                "originalFilename": "\(filename)",
                "byteSize": 74000000,
                "uploadedAt": "\(uploadedAt)"
            }
            """
        } ?? "null"

        let json = """
            {
                "id": "\(filename)",
                "originalFilename": "\(filename)",
                "heartCount": 0,
                "workflowStatus": "idle",
                "variants": {},
                "finalPhoto": null,
                "capturedAt": null,
                "pendingRawRequestCount": \(pendingRawRequestCount),
                "rawPhoto": \(rawPhoto)
            }
            """

        return try JSONDecoder().decode(
            ServerPhotoRecord.self,
            from: Data(json.utf8)
        )
    }

    @Test
    func pendingIsUndeliveredRequestsInFilenameOrder() throws {
        let photos = [
            try Self.photo(
                filename: "DSC01010.ARW",
                pendingRawRequestCount: 1,
                rawUploadedAt: nil
            ),
            try Self.photo(
                filename: "DSC01002.ARW",
                pendingRawRequestCount: 2,
                rawUploadedAt: nil
            ),
            // Re-requested after delivery: not pending again.
            try Self.photo(
                filename: "DSC01001.ARW",
                pendingRawRequestCount: 1,
                rawUploadedAt: "2026-09-09T00:00:00.000Z"
            ),
            try Self.photo(
                filename: "DSC01003.ARW",
                pendingRawRequestCount: 0,
                rawUploadedAt: nil
            ),
        ]

        #expect(
            RawRequestList.pending(in: photos)
                .map(\.originalFilename)
            == ["DSC01002.ARW", "DSC01010.ARW"]
        )
    }

    @Test
    func deliveredIsEveryStoredRawNewestFirst() throws {
        let photos = [
            try Self.photo(
                filename: "DSC01001.ARW",
                pendingRawRequestCount: 0,
                rawUploadedAt: "2026-09-08T10:00:00.000Z"
            ),
            try Self.photo(
                filename: "DSC01002.ARW",
                pendingRawRequestCount: 1,
                rawUploadedAt: "2026-09-09T10:00:00.000Z"
            ),
            try Self.photo(
                filename: "DSC01003.ARW",
                pendingRawRequestCount: 1,
                rawUploadedAt: nil
            ),
        ]

        #expect(
            RawRequestList.delivered(in: photos)
                .map(\.originalFilename)
            == ["DSC01002.ARW", "DSC01001.ARW"]
        )
    }
}
