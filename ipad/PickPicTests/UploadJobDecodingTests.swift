import Foundation
import Testing

@testable import PickPic

struct UploadJobDecodingTests {
    // Only the fields UploadJob.CodingKeys had before every later addition.
    // Real on-disk queues written before those additions look like this, so
    // CLAUDE.md trap #1 requires every newer field to decode from its
    // absence without throwing -- getting this wrong destroys in-flight
    // upload state on a user's device.
    private static let oldShapeJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "eventID": "evt-1",
            "eventTitle": "Old Event",
            "folderName": "OldFolder",
            "folderBookmarkData": "",
            "photos": [],
            "stage": "queued",
            "createdAt": 0,
            "updatedAt": 0
        }
        """

    @Test
    func oldShapeQueueDataStillDecodes() throws {
        let job = try JSONDecoder().decode(
            UploadJob.self,
            from: Data(Self.oldShapeJSON.utf8)
        )

        #expect(job.id.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(job.stage == .queued)
        #expect(job.preparedPhotos == [])
        #expect(job.preflight == nil)
        #expect(job.storageHeadroomWarningMessage == nil)
        #expect(job.storageHeadroomWarningAcknowledged == false)
        #expect(job.conversionProcessedCount == 0)
        #expect(job.conversionCurrentFilename == nil)
        #expect(job.conversionStartedAt == nil)
        #expect(job.conversionCompletedAt == nil)
        #expect(job.uploadProgress == .empty)
        #expect(job.continuedProcessing == nil)
    }

    @Test
    func oldShapeQueueArrayStillDecodes() throws {
        // Mirrors how UploadQueueStore decodes the persisted queue file: an
        // array of jobs, not a single job.
        let jobs = try JSONDecoder().decode(
            [UploadJob].self,
            from: Data("[\(Self.oldShapeJSON)]".utf8)
        )

        #expect(jobs.count == 1)
    }

    @Test
    func fullyPopulatedJobRoundTripsThroughEncodeAndDecode() throws {
        let original = UploadJob(
            id: UUID(),
            eventID: "evt-42",
            eventTitle: "Full Event",
            folderName: "FullFolder",
            folderBookmarkData: Data([0x01, 0x02, 0x03]),
            photos: [
                SourcePhoto(
                    filename: "DSC01015.ARW",
                    byteSize: 12_345,
                    kind: .raw
                )
            ],
            stage: .uploading,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            preparedAt: Date(timeIntervalSinceReferenceDate: 1_500),
            storageHeadroomWarningMessage: "Watch storage",
            storageHeadroomWarningAcknowledged: true,
            conversionProcessedCount: 3,
            conversionCurrentFilename: "DSC01015.ARW",
            conversionStartedAt: Date(timeIntervalSinceReferenceDate: 1_100)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UploadJob.self, from: data)

        #expect(decoded == original)
    }
}
