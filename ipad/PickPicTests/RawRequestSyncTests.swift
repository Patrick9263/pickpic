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
