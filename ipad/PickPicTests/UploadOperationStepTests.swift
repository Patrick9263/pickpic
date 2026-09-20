import Foundation
import Testing

@testable import PickPic

struct UploadOperationStepTests {
    @Test
    func proofUploadReportsItsOwnTitle() {
        #expect(
            UploadOperationStep.uploadCaptionTitle(
                for: .proofUpload
            ) == "Uploading proof JPEG"
        )
    }

    @Test
    func variantGenerationReportsVariantUploadTitleInstead() {
        #expect(
            UploadOperationStep.uploadCaptionTitle(
                for: .variantGeneration
            ) == UploadOperationStep.variantUpload.title
        )
    }

    @Test
    func variantUploadReportsItsOwnTitle() {
        #expect(
            UploadOperationStep.uploadCaptionTitle(
                for: .variantUpload
            ) == "Uploading thumbnail and preview"
        )
    }

    @Test
    func noStepFallsBackToTheDefaultMessage() {
        #expect(
            UploadOperationStep.uploadCaptionTitle(
                for: nil
            ) == "Uploading prepared JPEG…"
        )
    }
}
