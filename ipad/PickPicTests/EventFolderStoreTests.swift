import Foundation
import Testing

@testable import PickPic

@MainActor
struct EventFolderStoreTests {
    // The exact on-disk shape event-folders.json has always had: a map of
    // event id to a four-field reference, JSONEncoder defaults throughout
    // (Date as seconds since the reference date, Data as base64). Every
    // later field added to EventFolderReference has to keep decoding from
    // this, per CLAUDE.md trap 1.
    private static let originalShapeJSON = """
        {
            "evt-1": {
                "eventID": "evt-1",
                "folderName": "Wedding",
                "bookmarkData": "AQID",
                "updatedAt": 0
            }
        }
        """

    private static func makeStorageURL() throws -> URL {
        let directoryURL = URL(
            fileURLWithPath: NSTemporaryDirectory()
        )
        .appendingPathComponent(
            "EventFolderStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        return directoryURL.appendingPathComponent(
            "event-folders.json",
            isDirectory: false
        )
    }

    private static func makeJob(
        eventID: String
    ) -> UploadJob {
        UploadJob(
            id: UUID(),
            eventID: eventID,
            eventTitle: "Event \(eventID)",
            folderName: "Folder \(eventID)",
            folderBookmarkData: Data([0x09, 0x09]),
            photos: [],
            stage: .queued,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    @Test
    func originalFourFieldShapeStillDecodes() throws {
        let result = try EventFolderStore.decodeReferences(
            from: Data(Self.originalShapeJSON.utf8)
        )

        #expect(result.skippedCount == 0)
        #expect(result.references.count == 1)
        #expect(result.references["evt-1"]?.folderName == "Wedding")
        #expect(result.references["evt-1"]?.bookmarkData == Data([0x01, 0x02, 0x03]))
    }

    @Test
    func unknownFieldsFromANewerBuildAreIgnored() throws {
        // The mirror of the trap 1 case: a file written by a *newer* build
        // that added a field this build does not know about must still
        // decode, or downgrading would wipe the same bookmarks.
        let json = """
            {
                "evt-1": {
                    "eventID": "evt-1",
                    "folderName": "Wedding",
                    "bookmarkData": "AQID",
                    "updatedAt": 0,
                    "fieldFromTheFuture": "surprise"
                }
            }
            """

        let result = try EventFolderStore.decodeReferences(
            from: Data(json.utf8)
        )

        #expect(result.skippedCount == 0)
        #expect(result.references["evt-1"]?.folderName == "Wedding")
    }

    @Test
    func oneUnreadableEntryDoesNotDiscardTheOthers() throws {
        let json = """
            {
                "evt-good": {
                    "eventID": "evt-good",
                    "folderName": "Readable",
                    "bookmarkData": "AQID",
                    "updatedAt": 0
                },
                "evt-bad": {
                    "eventID": "evt-bad",
                    "folderName": "Missing a bookmark"
                }
            }
            """

        let result = try EventFolderStore.decodeReferences(
            from: Data(json.utf8)
        )

        #expect(result.skippedCount == 1)
        #expect(result.references.count == 1)
        #expect(result.references["evt-good"]?.folderName == "Readable")
    }

    @Test
    func missingFileStartsEmptyAndStaysWritable() throws {
        let storageURL = try Self.makeStorageURL()
        let store = EventFolderStore(storageURL: storageURL)

        #expect(store.references.isEmpty)
        #expect(store.loadErrorMessage == nil)

        try store.save(job: Self.makeJob(eventID: "evt-1"))

        #expect(store.reference(for: "evt-1")?.folderName == "Folder evt-1")
        #expect(
            FileManager.default.fileExists(atPath: storageURL.path)
        )
    }

    @Test
    func savedReferencesSurviveAReload() throws {
        let storageURL = try Self.makeStorageURL()
        let store = EventFolderStore(storageURL: storageURL)

        try store.save(job: Self.makeJob(eventID: "evt-1"))
        try store.save(job: Self.makeJob(eventID: "evt-2"))

        let reloaded = EventFolderStore(storageURL: storageURL)

        #expect(reloaded.references.count == 2)
        #expect(reloaded.reference(for: "evt-2")?.folderName == "Folder evt-2")
        #expect(reloaded.loadErrorMessage == nil)
    }

    // The issue #234 regression test. Before the fix, load() answered an
    // unreadable file with `references = [:]` and the next save() wrote
    // that empty map over it, destroying every bookmark on the device.
    @Test
    func unreadableFileIsNeverOverwrittenBySave() throws {
        let storageURL = try Self.makeStorageURL()
        let originalBytes = Data("this is not JSON at all".utf8)
        try originalBytes.write(to: storageURL)

        let store = EventFolderStore(storageURL: storageURL)

        #expect(store.loadErrorMessage != nil)

        #expect(throws: EventFolderStoreError.self) {
            try store.save(job: Self.makeJob(eventID: "evt-1"))
        }

        #expect(try Data(contentsOf: storageURL) == originalBytes)
    }

    @Test
    func unreadableFileIsNeverOverwrittenByRemove() throws {
        let storageURL = try Self.makeStorageURL()
        let originalBytes = Data("{ truncated".utf8)
        try originalBytes.write(to: storageURL)

        let store = EventFolderStore(storageURL: storageURL)

        #expect(throws: EventFolderStoreError.self) {
            try store.removeReference(for: "evt-1")
        }

        #expect(try Data(contentsOf: storageURL) == originalBytes)
    }

    // A file whose entries decode individually but not completely is the
    // shape a bad field addition would produce. The readable folders stay
    // usable, and the unreadable ones stay on disk for a corrected build.
    @Test
    func partiallyReadableFileIsReadableButNotWritable() throws {
        let storageURL = try Self.makeStorageURL()
        let originalBytes = Data(
            """
            {
                "evt-good": {
                    "eventID": "evt-good",
                    "folderName": "Readable",
                    "bookmarkData": "AQID",
                    "updatedAt": 0
                },
                "evt-bad": {
                    "eventID": "evt-bad"
                }
            }
            """.utf8
        )
        try originalBytes.write(to: storageURL)

        let store = EventFolderStore(storageURL: storageURL)

        #expect(store.reference(for: "evt-good")?.folderName == "Readable")
        #expect(store.reference(for: "evt-bad") == nil)
        #expect(store.loadErrorMessage != nil)

        #expect(throws: EventFolderStoreError.self) {
            try store.save(job: Self.makeJob(eventID: "evt-new"))
        }

        #expect(try Data(contentsOf: storageURL) == originalBytes)
    }

    @Test
    func emptyMapFileLoadsCleanlyAndStaysWritable() throws {
        let storageURL = try Self.makeStorageURL()
        try Data("{}".utf8).write(to: storageURL)

        let store = EventFolderStore(storageURL: storageURL)

        #expect(store.references.isEmpty)
        #expect(store.loadErrorMessage == nil)

        try store.save(job: Self.makeJob(eventID: "evt-1"))

        #expect(store.reference(for: "evt-1") != nil)
    }
}
