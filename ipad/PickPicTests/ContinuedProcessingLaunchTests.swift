import BackgroundTasks
import Foundation
import Testing

@testable import PickPic

struct ContinuedProcessingLaunchTests {
    private static let identifier =
        "photos.pickpic.app.processing.job"

    private static func state(
        status: ContinuedProcessingStatus,
        identifier: String = identifier,
        operation: ContinuedProcessingOperation =
            .prepareConvertAndUpload
    ) -> ContinuedProcessingState {
        ContinuedProcessingState(
            identifier: identifier,
            operation: operation,
            requestedAt: Date(timeIntervalSince1970: 0),
            status: status,
            startedAt: nil,
            endedAt: nil,
            message: nil
        )
    }

    @Test
    func aScheduledRequestIsAwaitingItsOwnLaunch() {
        #expect(
            Self.state(status: .scheduled).isAwaitingLaunch(
                identifier: Self.identifier,
                operation: .prepareConvertAndUpload
            )
        )
    }

    // The double-run guard: once the foreground fallback (or an earlier
    // launch) has claimed the job, a late iPadOS launch must be dismissed.
    @Test(arguments: [
        ContinuedProcessingStatus.active, .deferred, .foregroundFallback,
    ])
    func aClaimedRequestIsNoLongerAwaitingLaunch(
        status: ContinuedProcessingStatus
    ) {
        #expect(
            !Self.state(status: status).isAwaitingLaunch(
                identifier: Self.identifier,
                operation: .prepareConvertAndUpload
            )
        )
    }

    @Test
    func aLaunchForADifferentRequestIsNotThisOne() {
        let scheduled = Self.state(status: .scheduled)

        #expect(
            !scheduled.isAwaitingLaunch(
                identifier: "photos.pickpic.app.processing.other",
                operation: .prepareConvertAndUpload
            )
        )
        #expect(
            !scheduled.isAwaitingLaunch(
                identifier: Self.identifier,
                operation: .reconvertOnly
            )
        )
    }

    @Test
    func immediateRunIneligibleGetsTheBusySystemMessage() {
        let message = ContinuedProcessingTaskCoordinator
            .foregroundFallbackMessage(
                for: BGTaskScheduler.Error(
                    .immediateRunIneligible
                )
            )

        #expect(message.contains("right now"))
        #expect(message.contains("while the app remains open"))
    }

    @Test
    func otherSchedulerErrorsCarryTheirDescription() {
        let error = BGTaskScheduler.Error(.unavailable)
        let message = ContinuedProcessingTaskCoordinator
            .foregroundFallbackMessage(for: error)

        #expect(message.contains("unavailable"))
        #expect(message.contains(error.localizedDescription))
    }
}
