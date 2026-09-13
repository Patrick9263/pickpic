import Foundation
import Testing

@testable import PickPic

@MainActor
struct ToEditSyncServiceTests {
    private static func makeEventFolder() throws -> (URL, EventFolderReference) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "ToEditSyncServiceTests-\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        let bookmark = try dir.bookmarkData(options: [])

        let reference = EventFolderReference(
            eventID: "evt-1",
            folderName: "Test Event",
            bookmarkData: bookmark,
            updatedAt: Date()
        )

        return (dir, reference)
    }

    private static func photo(
        filename: String
    ) throws -> ServerPhotoRecord {
        let json = """
            {
                "id": "\(filename)",
                "originalFilename": "\(filename)",
                "heartCount": 1,
                "workflowStatus": "idle",
                "variants": {},
                "finalPhoto": null,
                "capturedAt": null
            }
            """

        return try JSONDecoder().decode(
            ServerPhotoRecord.self,
            from: Data(json.utf8)
        )
    }

    // #233: ToEditSyncService.sync used to throw out of its per-photo loop
    // on the first hash/copy/verification failure, so one unreadable RAW
    // (an undownloaded iCloud Drive placeholder is the realistic case)
    // silently stalled every other liked photo in the same event forever.
    @Test
    func oneUnreadableFileDoesNotAbortTheRestOfTheBatch() throws {
        let (dir, reference) = try Self.makeEventFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        let goodOneURL = dir.appendingPathComponent("good-1.jpg")
        let badURL = dir.appendingPathComponent("bad.jpg")
        let goodTwoURL = dir.appendingPathComponent("good-2.jpg")

        try Data("one".utf8).write(to: goodOneURL)
        try Data("bad".utf8).write(to: badURL)
        try Data("two".utf8).write(to: goodTwoURL)

        // Revoking read permission stands in for a file that exists but
        // can't be opened, the same failure shape as an iCloud Drive
        // placeholder that hasn't downloaded yet.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: badURL.path
        )

        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: badURL.path
            )
        }

        let photos = try [
            Self.photo(filename: "good-1.jpg"),
            Self.photo(filename: "bad.jpg"),
            Self.photo(filename: "good-2.jpg"),
        ]

        let result = try ToEditSyncService.sync(
            reference: reference,
            photos: photos
        )

        #expect(result.movedPhotoCount == 2)
        #expect(result.failedFilenames == ["bad.jpg"])
        #expect(
            result.syncedFilenames == ["good-1.jpg", "good-2.jpg"]
        )

        let toEditURL = dir.appendingPathComponent(
            UploadPreparationService.toEditFolderName,
            isDirectory: true
        )

        #expect(
            FileManager.default.fileExists(
                atPath: toEditURL
                    .appendingPathComponent("good-1.jpg").path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: toEditURL
                    .appendingPathComponent("good-2.jpg").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: toEditURL
                    .appendingPathComponent("bad.jpg").path
            )
        )
    }
}
