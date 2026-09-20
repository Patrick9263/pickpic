import Foundation
import Testing

@testable import PickPic

struct EventJobCountsTests {
    private static func makeJob(
        stage: UploadStage,
        lastFailure: UploadFailure? = nil,
        isWaitingForConnectivity: Bool = false
    ) -> UploadJob {
        var uploadProgress = UploadProgress.empty
        uploadProgress.lastFailure = lastFailure
        uploadProgress.waitingForConnectivitySince =
            isWaitingForConnectivity ? Date() : nil

        return UploadJob(
            id: UUID(),
            eventID: "evt-1",
            eventTitle: "Event",
            folderName: "Folder",
            folderBookmarkData: Data([0x01]),
            photos: [],
            stage: stage,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0),
            uploadProgress: uploadProgress
        )
    }

    private static func makeFailure(
        isNetworkRelated: Bool = false
    ) -> UploadFailure {
        UploadFailure(
            sourceFilename: "DSC01015.ARW",
            step: .proofUpload,
            message: "Upload failed",
            occurredAt: Date(timeIntervalSinceReferenceDate: 0),
            isNetworkRelated: isNetworkRelated
        )
    }

    @Test
    func completedJobsAreNotUnfinished() {
        let counts = EventJobCounts(jobs: [
            Self.makeJob(stage: .completed),
            Self.makeJob(stage: .completed),
        ])

        #expect(counts.unfinishedJobCount == 0)
        #expect(counts.stalledJobCount == 0)
        #expect(counts.activeJobCount == 0)
    }

    @Test
    func failedJobsAreStalledAndUnfinished() {
        let counts = EventJobCounts(jobs: [
            Self.makeJob(stage: .failed),
        ])

        #expect(counts.unfinishedJobCount == 1)
        #expect(counts.stalledJobCount == 1)
        #expect(counts.activeJobCount == 0)
    }

    @Test
    func readyToUploadWithFailureIsStalledOnlyWhenNotWaitingForConnectivity() {
        let stalled = EventJobCounts(jobs: [
            Self.makeJob(
                stage: .readyToUpload,
                lastFailure: Self.makeFailure(),
                isWaitingForConnectivity: false
            ),
        ])

        #expect(stalled.stalledJobCount == 1)

        let waiting = EventJobCounts(jobs: [
            Self.makeJob(
                stage: .readyToUpload,
                lastFailure: Self.makeFailure(),
                isWaitingForConnectivity: true
            ),
        ])

        #expect(waiting.stalledJobCount == 0)
        #expect(waiting.unfinishedJobCount == 1)
    }

    @Test(arguments: [
        UploadStage.preparing, .preflighting, .converting, .uploading,
    ])
    func activeOperationStagesCountAsActive(stage: UploadStage) {
        let counts = EventJobCounts(jobs: [Self.makeJob(stage: stage)])

        #expect(counts.activeJobCount == 1)
        #expect(counts.stalledJobCount == 0)
    }

    @Test
    func rowIdentitySuffixChangesWhenCountsChange() {
        let before = EventJobCounts(jobs: [
            Self.makeJob(stage: .uploading),
        ])

        let after = EventJobCounts(jobs: [
            Self.makeJob(stage: .completed),
        ])

        #expect(before.rowIdentitySuffix != after.rowIdentitySuffix)
    }
}
