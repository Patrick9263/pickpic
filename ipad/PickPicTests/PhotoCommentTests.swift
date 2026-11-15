import Foundation
import Testing

@testable import PickPic

struct ServerPhotoRecordCommentTests {
    private static func decode(
        heartCount: Int = 0,
        commentsJSON: String?
    ) throws -> ServerPhotoRecord {
        let commentsField =
        commentsJSON.map { ",\n\"comments\": \($0)" } ?? ""

        let json = """
            {
                "id": "photo-1",
                "originalFilename": "DSC01015.ARW",
                "heartCount": \(heartCount),
                "workflowStatus": "idle",
                "variants": {},
                "finalPhoto": null,
                "capturedAt": null\(commentsField)
            }
            """

        return try JSONDecoder().decode(
            ServerPhotoRecord.self,
            from: Data(json.utf8)
        )
    }

    // Carries the worker's full record shape, including the fields the
    // iPad ignores, to prove they do not get in the way.
    private static func comment(
        id: String,
        body: String,
        createdAt: String
    ) -> String {
        """
        {
            "id": "\(id)",
            "photoId": "photo-1",
            "displayName": "Sarah",
            "body": "\(body)",
            "createdAt": "\(createdAt)",
            "updatedAt": "\(createdAt)",
            "resolvedAt": null
        }
        """
    }

    // A response without the key must cost the comments, not the photo
    // list (CLAUDE.md trap #1).
    @Test
    func aResponseWithoutCommentsStillDecodes() throws {
        let photo = try Self.decode(commentsJSON: nil)

        #expect(photo.photoComments.isEmpty)
        #expect(photo.latestComment == nil)
        #expect(!photo.hasViewerRequest)
    }

    @Test
    func commentsReadOldestFirstWhateverOrderTheyArrive() throws {
        let later = Self.comment(
            id: "c2",
            body: "Crop out the sign",
            createdAt: "2026-11-14T18:05:00.000Z"
        )
        let earlier = Self.comment(
            id: "c1",
            body: "Brighten her face",
            createdAt: "2026-11-14T18:01:00.000Z"
        )

        let photo = try Self.decode(
            commentsJSON: "[\(later), \(earlier)]"
        )

        #expect(photo.photoComments.map(\.id) == ["c1", "c2"])
        #expect(photo.latestComment?.body == "Crop out the sign")
    }

    @Test
    func aCommentWithoutAHeartIsStillARequest() throws {
        let comment = Self.comment(
            id: "c1",
            body: "Can I get this one?",
            createdAt: "2026-11-14T18:01:00.000Z"
        )

        let photo = try Self.decode(
            heartCount: 0,
            commentsJSON: "[\(comment)]"
        )

        #expect(photo.hasViewerRequest)
    }

    @Test
    func aHeartWithoutCommentsIsARequest() throws {
        let photo = try Self.decode(
            heartCount: 2,
            commentsJSON: "[]"
        )

        #expect(photo.hasViewerRequest)
    }

    @Test
    func createdAtParsesWithAndWithoutMilliseconds() {
        let withMilliseconds = ServerPhotoComment(
            id: "c1",
            displayName: "Sarah",
            body: "x",
            createdAt: "2026-11-14T18:01:00.000Z"
        )
        let withoutMilliseconds = ServerPhotoComment(
            id: "c2",
            displayName: "Sarah",
            body: "x",
            createdAt: "2026-11-14T18:01:00Z"
        )
        let unparseable = ServerPhotoComment(
            id: "c3",
            displayName: "Sarah",
            body: "x",
            createdAt: "yesterday"
        )

        #expect(withMilliseconds.createdAtDate != nil)
        #expect(
            withMilliseconds.createdAtDate
                == withoutMilliseconds.createdAtDate
        )
        #expect(unparseable.createdAtDate == nil)
    }
}
