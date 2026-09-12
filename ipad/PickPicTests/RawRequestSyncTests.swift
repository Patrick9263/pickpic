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
