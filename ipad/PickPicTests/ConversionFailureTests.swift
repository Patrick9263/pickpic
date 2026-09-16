import Foundation
import Testing

@testable import PickPic

// One unconvertible RAW used to abort the whole batch, so the rule that
// decides skip-this-photo from stop-the-batch is the load-bearing piece
// of that fix: classify a bad frame as fatal and 1,199 good photos stay
// unconverted, classify a full disk as per-photo and the batch burns
// through every remaining frame to produce nothing.
struct ConversionFailureClassificationTests {
    @Test
    func perFileConversionErrorsSkipOnlyThatPhoto() {
        let perFileErrors: [ImageConversionError] = [
            .sourcePhotoMissing("DSC01015.ARW"),
            .unsupportedRAW("DSC01015.ARW"),
            .unableToDecode("DSC01015.ARW"),
            .outputFileMissing,
            .outputTooLarge("DSC01015.ARW", 30_000_000)
        ]

        for error in perFileErrors {
            #expect(error.isSinglePhotoFailure)
            #expect(
                ImageConversionService
                    .isSinglePhotoFailure(error)
            )
        }
    }

    @Test
    func batchWideConversionErrorsStopTheBatch() {
        let batchErrors: [ImageConversionError] = [
            .noSourcePhotos,
            .sourceFolderUnavailable,
            .unableToCreateColorSpace
        ]

        for error in batchErrors {
            #expect(!error.isSinglePhotoFailure)
            #expect(
                !ImageConversionService
                    .isSinglePhotoFailure(error)
            )
        }
    }

    @Test
    func unrecognisedErrorsSkipThePhoto() {
        // ImageIO and CoreImage report a truncated or unreadable file as
        // an arbitrary error rather than one of ours, so the permissive
        // default is what actually keeps a bad frame from wedging a shoot.
        let error = NSError(
            domain: "CINonexistentDomain",
            code: 4,
            userInfo: nil
        )

        #expect(
            ImageConversionService
                .isSinglePhotoFailure(error)
        )
    }

    @Test
    func cancellationStopsTheBatch() {
        #expect(
            !ImageConversionService
                .isSinglePhotoFailure(
                    CancellationError()
                )
        )
    }

    @Test
    func outOfSpaceStopsTheBatch() {
        let cocoaError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError,
            userInfo: nil
        )

        let posixError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: nil
        )

        #expect(
            !ImageConversionService
                .isSinglePhotoFailure(cocoaError)
        )
        #expect(
            !ImageConversionService
                .isSinglePhotoFailure(posixError)
        )
    }

    @Test
    func wrappedOutOfSpaceStopsTheBatch() {
        // CoreImage hands back its own error with the write failure
        // underneath, which is the shape this actually arrives in.
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: nil
        )

        let wrapped = NSError(
            domain: "CIImageRepresentation",
            code: 1,
            userInfo: [
                NSUnderlyingErrorKey: underlying
            ]
        )

        #expect(
            !ImageConversionService
                .isSinglePhotoFailure(wrapped)
        )
    }
}

struct UnconvertiblePhotoCountTests {
    private func makeJob(
        photoCount: Int,
        failedFilenames: [String]
    ) -> UploadJob {
        let photos = (0..<photoCount).map { index in
            SourcePhoto(
                filename: String(
                    format: "DSC%05d.ARW",
                    index
                ),
                byteSize: 1_000,
                kind: .raw
            )
        }

        let failures = failedFilenames.map { filename in
            ConversionFailure(
                sourcePhotoID: filename,
                sourceFilename: filename,
                message: "Could not decode \(filename).",
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
            createdAt: Date(
                timeIntervalSinceReferenceDate: 0
            ),
            updatedAt: Date(
                timeIntervalSinceReferenceDate: 0
            ),
            conversionFailures: failures
        )
    }

    @Test
    func skippedPhotosLeaveTheBatchCompletable() {
        // photosToConvertCount is what preparedPhotos.count is compared
        // against before an upload starts, so a skipped photo has to come
        // out of it or the batch can never be called complete.
        let job = makeJob(
            photoCount: 10,
            failedFilenames: [
                "DSC00003.ARW",
                "DSC00007.ARW"
            ]
        )

        #expect(job.unconvertiblePhotoCount == 2)
        #expect(job.photosToConvertCount == 8)
    }

    @Test
    func aJobWithNoFailuresConvertsEveryPhoto() {
        let job = makeJob(
            photoCount: 10,
            failedFilenames: []
        )

        #expect(job.unconvertiblePhotoCount == 0)
        #expect(job.photosToConvertCount == 10)
    }

    @Test
    func everyPhotoFailingLeavesNothingToConvert() {
        let job = makeJob(
            photoCount: 3,
            failedFilenames: [
                "DSC00000.ARW",
                "DSC00001.ARW",
                "DSC00002.ARW"
            ]
        )

        #expect(job.photosToConvertCount == 0)
    }
}
