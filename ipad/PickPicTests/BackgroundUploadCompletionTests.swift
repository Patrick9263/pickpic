import Foundation
import Testing

@testable import PickPic

// Covers how a finished background transfer is classified, which is what
// decides whether the job re-verifies or lands in a red failure state.
// The handler that acts on it (handleRestoredBackgroundUploadCompletion)
// is @MainActor and needs an APIConfigurationStore, so it stays outside
// this target -- same boundary #136 and #151 drew.
struct BackgroundUploadCompletionTests {
    private static func makeCompletion(
        statusCode: Int? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        errorMessage: String? = nil
    ) -> BackgroundUploadCompletion {
        BackgroundUploadCompletion(
            context: BackgroundUploadContext(
                jobID: UUID(),
                sourceFilename: "DSC01015.ARW",
                step: .proofUpload,
                createdAt: Date(
                    timeIntervalSinceReferenceDate: 100
                )
            ),
            statusCode: statusCode,
            errorDomain: errorDomain,
            errorCode: errorCode,
            errorMessage: errorMessage,
            completedAt: Date(
                timeIntervalSinceReferenceDate: 200
            )
        )
    }

    // The relaunch case: nsurlsessiond cancels the still-running task when
    // a new session claims the same background identifier, and reports
    // NSURLErrorCancelled. Before this was recognised it fell through to
    // the generic failure branch and surfaced as a red "Upload stopped"
    // showing the raw NSError text.
    @Test
    func relaunchCancellationIsRecognisedAsCancelled() {
        let completion = Self.makeCompletion(
            errorDomain: NSURLErrorDomain,
            errorCode: URLError.Code.cancelled.rawValue,
            errorMessage: "The operation couldn't be completed. (NSURLErrorDomain error -999.)"
        )

        #expect(completion.wasCancelled)
        #expect(completion.succeeded == false)
        #expect(
            completion.shouldRetryWhenConnectivityReturns
                == false
        )
    }

    @Test
    func successfulTransferIsNotCancelled() {
        let completion = Self.makeCompletion(
            statusCode: 201
        )

        #expect(completion.succeeded)
        #expect(completion.wasCancelled == false)
    }

    @Test
    func connectivityFailureIsNotCancelled() {
        let completion = Self.makeCompletion(
            errorDomain: NSURLErrorDomain,
            errorCode: URLError.Code
                .notConnectedToInternet
                .rawValue
        )

        #expect(completion.wasCancelled == false)
        #expect(completion.succeeded == false)
        #expect(completion.shouldRetryWhenConnectivityReturns)
    }

    // The domain is checked, not just the code. Another framework's -999
    // means something else entirely and must not be waved through as a
    // benign cancellation.
    @Test
    func cancelledCodeInAnotherDomainIsNotCancelled() {
        let completion = Self.makeCompletion(
            errorDomain: "com.example.SomeOtherDomain",
            errorCode: URLError.Code.cancelled.rawValue
        )

        #expect(completion.wasCancelled == false)
    }

    @Test
    func serverErrorIsNeitherSuccessNorCancellation() {
        let completion = Self.makeCompletion(
            statusCode: 500
        )

        #expect(completion.succeeded == false)
        #expect(completion.wasCancelled == false)
        #expect(
            completion.shouldRetryWhenConnectivityReturns
                == false
        )
    }
}
