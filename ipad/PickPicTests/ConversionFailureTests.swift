import Foundation
import Testing

@testable import PickPic

struct ConversionFailureTests {
    private static func makeJob(
        photoCount: Int,
        preparedCount: Int = 0,
        failedFilenames: [String] = []
    ) -> UploadJob {
        let photos = (0..<photoCount).map { index in
            SourcePhoto(
                filename: String(
                    format: "DSC%05d.ARW",
                    index
                ),
                byteSize: 60_000_000,
                kind: .raw
            )
        }

        let preparedPhotos = photos
            .prefix(preparedCount)
            .enumerated()
            .map { index, photo in
                PreparedPhoto(
                    sourcePhotoID: photo.id,
                    sourceFilename: photo.filename,
                    outputFilename: "proof-\(index).jpg",
                    sourceSha256: "hash-\(index)",
                    byteSize: 2_000_000,
                    pixelWidth: 2_400,
                    pixelHeight: 1_600,
                    metadata: .empty,
                    preparedAt: Date(
                        timeIntervalSinceReferenceDate: 0
                    )
                )
            }

        let failures = failedFilenames.map { filename in
            ConversionFailure(
                sourcePhotoID: "source-v1|raw|60000000|\(filename.lowercased())",
                sourceFilename: filename,
                message: "The RAW file \(filename) could not be decoded on this iPad.",
                occurredAt: Date(
                    timeIntervalSinceReferenceDate: 0
                )
            )
        }

        return UploadJob(
            id: UUID(),
            eventID: "evt-1",
            eventTitle: "Event",
            folderName: "Folder",
            folderBookmarkData: Data(),
            photos: photos,
            stage: .converting,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0),
            preparedPhotos: Array(preparedPhotos),
            conversionFailures: failures,
            conversionProcessedCount: preparedCount
        )
    }

    // The invariant the upload path gates on: a batch is complete when it
    // holds a prepared JPEG for every photo it meant to convert, minus the
    // frames conversion gave up on. Without the subtraction, one skipped
    // RAW leaves the batch permanently "incomplete" and nothing uploads.
    @Test
    func skippedFramesLeaveTheBatchComplete() {
        let job = makeJobWithThreeConvertedAndOneSkipped()

        #expect(job.photosToConvertCount == 4)
        #expect(job.unconvertiblePhotoCount == 1)
        #expect(job.expectedPreparedPhotoCount == 3)
        #expect(
            job.preparedPhotos.count
                == job.expectedPreparedPhotoCount
        )
    }

    private func makeJobWithThreeConvertedAndOneSkipped() -> UploadJob {
        Self.makeJob(
            photoCount: 4,
            preparedCount: 3,
            failedFilenames: ["DSC00003.ARW"]
        )
    }

    @Test
    func progressCountsSkippedFramesAsAttempted() {
        let job = makeJobWithThreeConvertedAndOneSkipped()

        #expect(job.conversionAttemptedCount == 4)
        #expect(
            job.conversionAttemptedCount
                == job.photosToConvertCount
        )
    }

    @Test
    func batchWithNoFailuresIsUnaffected() {
        let job = Self.makeJob(
            photoCount: 4,
            preparedCount: 4
        )

        #expect(job.unconvertiblePhotoCount == 0)
        #expect(job.expectedPreparedPhotoCount == 4)
        #expect(job.conversionAttemptedCount == 4)
    }

    // Defensive: a failure list that somehow outgrew the batch must not
    // produce a negative expected count, which would compare unequal to
    // any real prepared count and wedge the upload.
    @Test
    func expectedPreparedCountNeverGoesNegative() {
        let job = Self.makeJob(
            photoCount: 1,
            failedFilenames: [
                "DSC00000.ARW",
                "DSC00001.ARW",
                "DSC00002.ARW"
            ]
        )

        #expect(job.expectedPreparedPhotoCount == 0)
    }

    // One bad frame is that frame's problem; these must be skipped rather
    // than abort the batch, which is the whole point of the change.
    @Test
    func perPhotoFailuresDoNotStopTheBatch() {
        let perPhotoErrors: [ImageConversionError] = [
            .sourcePhotoMissing("DSC00001.ARW"),
            .unsupportedRAW("DSC00001.ARW"),
            .unableToDecode("DSC00001.ARW"),
            .outputFileMissing,
            .outputTooLarge("DSC00001.ARW", 30_000_000)
        ]

        for error in perPhotoErrors {
            #expect(
                ImageConversionService
                    .failureStopsBatch(error) == false
            )
        }
    }

    // A missing file resolves to a Cocoa read error rather than
    // ImageConversionError, and it is still one frame's problem.
    @Test
    func missingFileErrorDoesNotStopTheBatch() {
        let error = CocoaError(.fileReadNoSuchFile)

        #expect(
            ImageConversionService
                .failureStopsBatch(error) == false
        )
    }

    // These would fail every remaining photo in turn, so the batch stops
    // instead of recording a thousand identical failures.
    @Test
    func batchWideFailuresStopTheBatch() {
        #expect(
            ImageConversionService.failureStopsBatch(
                ImageConversionError
                    .sourceFolderUnavailable
            )
        )
        #expect(
            ImageConversionService.failureStopsBatch(
                ImageConversionError.noSourcePhotos
            )
        )
        #expect(
            ImageConversionService.failureStopsBatch(
                ImageConversionError
                    .unableToCreateColorSpace
            )
        )
        #expect(
            ImageConversionService.failureStopsBatch(
                CancellationError()
            )
        )
        #expect(
            ImageConversionService.failureStopsBatch(
                CocoaError(.fileWriteOutOfSpace)
            )
        )
        #expect(
            ImageConversionService.failureStopsBatch(
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOSPC)
                )
            )
        )
    }

    // CLAUDE.md trap #1: a queue file written before conversionFailures
    // existed must still decode, and must decode to an empty list rather
    // than throwing away the job.
    @Test
    func queueWithoutConversionFailuresStillDecodes() throws {
        let json = """
            {
                "id": "22222222-2222-2222-2222-222222222222",
                "eventID": "evt-1",
                "eventTitle": "Old Event",
                "folderName": "OldFolder",
                "folderBookmarkData": "",
                "photos": [],
                "stage": "readyToUpload",
                "createdAt": 0,
                "updatedAt": 0
            }
            """

        let job = try JSONDecoder().decode(
            UploadJob.self,
            from: Data(json.utf8)
        )

        #expect(job.conversionFailures == [])
        #expect(job.unconvertiblePhotoCount == 0)
    }
}
