import Foundation
import Testing

@testable import PickPic

// Covers the storage seam added by #169 step 1 -- init(storageURL:)
// letting a store be pointed at a temp file instead of the real app-support
// directory -- and, since #399 step 1, the store's small queue operations
// (renameEvent, adoptUnownedJobs, add, estimatedProofSize,
// completedJobCount), each asserted in memory and again after a second
// store re-opens the same file. Recovery-walk semantics (readyToUpload
// demotion, continued-processing, etc.) live in UploadQueueRecoveryTests.
//
// Deliberately absent: remove(jobIDs:) and anything reaching
// submitContinuedProcessing, which touch the ContinuedProcessingTaskCoordinator
// and BackgroundUploadSession singletons. Jobs here use stage .queued or
// .completed so load()'s recovery walk leaves them untouched.
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
        // The recovery walk never ran, so there is nothing to announce --
        // a launch that could not read the queue must not also claim it
        // restored something.
        #expect(store.recoveryMessage == nil)
    }

    // MARK: - Queue operations (#399 step 1)

    private static func makeJob(
        eventID: String,
        eventTitle: String? = nil,
        accountID: String? = nil,
        stage: UploadStage = .queued,
        createdAt: TimeInterval = 0,
        updatedAt: TimeInterval = 0,
        preparedByteSizes: [Int64] = []
    ) -> UploadJob {
        UploadJob(
            id: UUID(),
            eventID: eventID,
            eventTitle: eventTitle ?? "Event \(eventID)",
            accountID: accountID,
            folderName: "Folder \(eventID)",
            folderBookmarkData: Data([0x09, 0x09]),
            photos: [],
            stage: stage,
            createdAt: Date(
                timeIntervalSinceReferenceDate: createdAt
            ),
            updatedAt: Date(
                timeIntervalSinceReferenceDate: updatedAt
            ),
            preparedPhotos: preparedByteSizes.enumerated().map {
                index, byteSize in
                PreparedPhoto(
                    sourceFilename: "DSC\(index).ARW",
                    outputFilename: "DSC\(index).jpg",
                    sourceSha256: String(repeating: "a", count: 64),
                    byteSize: byteSize,
                    pixelWidth: 3_000,
                    pixelHeight: 2_000,
                    metadata: .empty,
                    preparedAt: Date(timeIntervalSinceReferenceDate: 0)
                )
            }
        )
    }

    @Test
    func addKeepsTheQueueNewestFirst() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        let oldest = Self.makeJob(eventID: "old", createdAt: 100)
        let newest = Self.makeJob(eventID: "new", createdAt: 300)
        let middle = Self.makeJob(eventID: "mid", createdAt: 200)

        try store.add(oldest)
        try store.add(newest)
        try store.add(middle)

        let expected = [newest.id, middle.id, oldest.id]

        #expect(store.jobs.map(\.id) == expected)

        let reloaded = UploadQueueStore(storageURL: storageURL)

        #expect(reloaded.jobs.map(\.id) == expected)
    }

    @Test
    func renameEventRewritesEveryJobOfTheEventAndNoOther() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        let first = Self.makeJob(
            eventID: "evt-1",
            eventTitle: "Old name",
            createdAt: 1
        )
        let second = Self.makeJob(
            eventID: "evt-1",
            eventTitle: "Old name",
            createdAt: 2
        )
        let other = Self.makeJob(
            eventID: "evt-2",
            eventTitle: "Old name",
            createdAt: 3
        )

        try store.add(first)
        try store.add(second)
        try store.add(other)

        store.renameEvent(eventID: "evt-1", title: "New name")

        func titles(_ jobs: [UploadJob]) -> [UUID: String] {
            Dictionary(
                uniqueKeysWithValues: jobs.map { ($0.id, $0.eventTitle) }
            )
        }

        let expected = [
            first.id: "New name",
            second.id: "New name",
            other.id: "Old name",
        ]

        #expect(titles(store.jobs) == expected)
        #expect(store.loadErrorMessage == nil)

        let reloaded = UploadQueueStore(storageURL: storageURL)

        #expect(titles(reloaded.jobs) == expected)
    }

    @Test
    func renameEventToTheSameTitleDoesNotRewriteTheFile() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        try store.add(
            Self.makeJob(eventID: "evt-1", eventTitle: "Same")
        )

        // Replacing the file with a sentinel proves nothing is saved: a
        // rewrite would overwrite it with a valid queue again.
        try Data("sentinel".utf8).write(to: storageURL)

        store.renameEvent(eventID: "evt-1", title: "Same")
        store.renameEvent(eventID: "unknown", title: "Anything")

        #expect(
            try Data(contentsOf: storageURL) == Data("sentinel".utf8)
        )
        #expect(store.jobs.first?.eventTitle == "Same")
    }

    @Test
    func adoptUnownedJobsStampsOnlyJobsWithoutAnAccount() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        let unowned = Self.makeJob(eventID: "evt-1", createdAt: 1)
        let owned = Self.makeJob(
            eventID: "evt-2",
            accountID: "acct-other",
            createdAt: 2
        )

        try store.add(unowned)
        try store.add(owned)

        store.adoptUnownedJobs(accountID: "acct-new")

        func accounts(_ jobs: [UploadJob]) -> [UUID: String?] {
            Dictionary(
                uniqueKeysWithValues: jobs.map { ($0.id, $0.accountID) }
            )
        }

        let expected: [UUID: String?] = [
            unowned.id: "acct-new",
            owned.id: "acct-other",
        ]

        #expect(accounts(store.jobs) == expected)

        let reloaded = UploadQueueStore(storageURL: storageURL)

        #expect(accounts(reloaded.jobs) == expected)
    }

    @Test
    func adoptUnownedJobsIsANoOpWhenEveryJobIsOwned() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        try store.add(
            Self.makeJob(eventID: "evt-1", accountID: "acct-a")
        )

        try Data("sentinel".utf8).write(to: storageURL)

        store.adoptUnownedJobs(accountID: "acct-b")

        #expect(store.jobs.first?.accountID == "acct-a")
        #expect(
            try Data(contentsOf: storageURL) == Data("sentinel".utf8)
        )
    }

    @Test
    func completedJobCountCountsOnlyCompletedJobsOfThatEvent() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        try store.add(
            Self.makeJob(eventID: "evt-1", stage: .completed, createdAt: 1)
        )
        try store.add(
            Self.makeJob(eventID: "evt-1", stage: .completed, createdAt: 2)
        )
        try store.add(
            Self.makeJob(eventID: "evt-1", stage: .queued, createdAt: 3)
        )
        try store.add(
            Self.makeJob(eventID: "evt-2", stage: .completed, createdAt: 4)
        )

        #expect(store.completedJobCount(for: "evt-1") == 2)
        #expect(store.completedJobCount(for: "evt-2") == 1)
        #expect(store.completedJobCount(for: "evt-3") == 0)

        let reloaded = UploadQueueStore(storageURL: storageURL)

        #expect(reloaded.completedJobCount(for: "evt-1") == 2)
        #expect(reloaded.completedJobCount(for: "evt-2") == 1)
    }

    // MARK: estimatedProofSize

    @Test
    func proofSizeEstimateIsNilWithoutPhotosOrSamples() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        #expect(store.estimatedProofSize(forPhotoCount: 10) == nil)

        // A job with no prepared photos is no sample.
        try store.add(Self.makeJob(eventID: "evt-1", stage: .completed))

        #expect(store.estimatedProofSize(forPhotoCount: 10) == nil)

        // Prepared photos that all report zero bytes give no usable average.
        try store.add(
            Self.makeJob(
                eventID: "evt-2",
                stage: .completed,
                preparedByteSizes: [0, 0]
            )
        )

        #expect(store.estimatedProofSize(forPhotoCount: 10) == nil)

        // Zero photos to estimate is nil even with good samples.
        try store.add(
            Self.makeJob(
                eventID: "evt-3",
                stage: .completed,
                preparedByteSizes: [1_000]
            )
        )

        #expect(store.estimatedProofSize(forPhotoCount: 0) == nil)
        #expect(store.estimatedProofSize(forPhotoCount: 1) != nil)
    }

    @Test
    func proofSizeEstimateAveragesAndRoundsToWholeBytes() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        // 10 bytes over 3 photos: 3.33... bytes each.
        try store.add(
            Self.makeJob(
                eventID: "evt-1",
                stage: .completed,
                preparedByteSizes: [3, 3, 4]
            )
        )

        // 3.33 rounds down, 6.67 rounds up.
        #expect(
            store.estimatedProofSize(forPhotoCount: 1)?.byteCount == 3
        )
        #expect(
            store.estimatedProofSize(forPhotoCount: 2)?.byteCount == 7
        )
        #expect(
            store.estimatedProofSize(forPhotoCount: 1)?.sampleJobCount
                == 1
        )

        let reloaded = UploadQueueStore(storageURL: storageURL)

        #expect(
            reloaded.estimatedProofSize(forPhotoCount: 2)?.byteCount
                == 7
        )
    }

    @Test
    func proofSizeEstimateSamplesTheFiveMostRecentlyUpdatedJobs() throws {
        let storageURL = try Self.makeStorageURL()
        let store = UploadQueueStore(storageURL: storageURL)

        // The stalest job is enormous; if it leaked into the sample the
        // average would be nowhere near 1,000.
        try store.add(
            Self.makeJob(
                eventID: "stale",
                stage: .completed,
                createdAt: 0,
                updatedAt: 0,
                preparedByteSizes: [1_000_000]
            )
        )

        for index in 1...5 {
            try store.add(
                Self.makeJob(
                    eventID: "evt-\(index)",
                    stage: .completed,
                    createdAt: TimeInterval(index),
                    updatedAt: TimeInterval(index),
                    preparedByteSizes: [1_000, 1_000]
                )
            )
        }

        // A job with nothing prepared is filtered out before the cut-off,
        // so it neither counts as a sample nor displaces one.
        try store.add(
            Self.makeJob(
                eventID: "empty",
                stage: .completed,
                createdAt: 6,
                updatedAt: 6
            )
        )

        let estimate = store.estimatedProofSize(forPhotoCount: 7)

        #expect(estimate?.byteCount == 7_000)
        #expect(estimate?.sampleJobCount == 5)

        let reloaded = UploadQueueStore(storageURL: storageURL)
        let reloadedEstimate = reloaded.estimatedProofSize(
            forPhotoCount: 7
        )

        #expect(reloadedEstimate?.byteCount == 7_000)
        #expect(reloadedEstimate?.sampleJobCount == 5)
    }
}
