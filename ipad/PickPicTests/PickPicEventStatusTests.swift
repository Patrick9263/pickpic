import Testing

@testable import PickPic

struct PickPicEventStatusTests {
    @Test(arguments: [
        PickPicEvent.Status.ready, .completed,
    ])
    func statusesWithPendingWorkReportTrue(status: PickPicEvent.Status) {
        #expect(status.mayHavePendingGalleryWork)
    }

    @Test(arguments: [
        PickPicEvent.Status.draft, .archived,
    ])
    func statusesWithNoPendingWorkReportFalse(status: PickPicEvent.Status) {
        #expect(!status.mayHavePendingGalleryWork)
    }
}
