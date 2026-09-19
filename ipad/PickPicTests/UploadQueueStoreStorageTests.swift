import Foundation
import Testing

@testable import PickPic

// Covers only the storage seam added by #169 step 1 -- init(storageURL:)
// letting a store be pointed at a temp file instead of the real app-support
// directory. Recovery-walk semantics (readyToUpload demotion, continued-
// processing, etc.) are step 2's territory and stay untested here.
@MainActor
struct UploadQueueStoreStorageTests {
    private static func makeStorageURL() throws -> URL {
        let directoryURL = URL(
            fileURLWithPath: NSTemporaryDirectory()
        )
        .appendingPathComponent(
            "UploadQueueStoreStorageTests-\(UUID().uuidString)",
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        return directoryURL.appendingPathComponent(
            "upload-queue.json",
            isDirectory: false
        )
    }

    // Empty photos/stage .queued survives load()'s recovery walk untouched:
    // it has no continuedProcessing state and isn't in .prepared or
    // .readyToUpload, so none of the stage-transform branches fire.
    private static func makePassthroughJob(
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
    func missingFileStartsEmptyAndStaysWritable() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        #expect(store.jobs.isEmpty)
        #expect(store.loadErrorMessage == nil)

        try store.add(Self.makePassthroughJob(eventID: "evt-1"))

        #expect(
            FileManager.default.fileExists(atPath: storageURL.path)
        )
    }

    @Test
    func savedJobsSurviveAReloadAtTheSameStorageURL() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        let job = Self.makePassthroughJob(eventID: "evt-1")
        try store.add(job)

        let reloaded = UploadQueueStore(storageURL: storageURL)

        #expect(reloaded.jobs.count == 1)
        #expect(reloaded.jobs.first?.id == job.id)
        #expect(reloaded.jobs.first?.eventID == "evt-1")
        #expect(reloaded.loadErrorMessage == nil)
    }

    @Test
    func distinctStorageURLsDoNotShareState() throws {
        let firstStorageURL = try Self.makeStorageURL()
        let secondStorageURL = try Self.makeStorageURL()

        let first = UploadQueueStore(storageURL: firstStorageURL)
        try first.add(Self.makePassthroughJob(eventID: "evt-1"))

        let second = UploadQueueStore(storageURL: secondStorageURL)

        #expect(second.jobs.isEmpty)
    }

    @Test
    func unreadableFileSetsLoadErrorInsteadOfCrashing() throws {
        let storageURL = try Self.makeStorageURL()
        try Data("this is not JSON at all".utf8).write(to: storageURL)

        let store = UploadQueueStore(storageURL: storageURL)

        #expect(store.jobs.isEmpty)
        #expect(store.loadErrorMessage != nil)
    }
}
