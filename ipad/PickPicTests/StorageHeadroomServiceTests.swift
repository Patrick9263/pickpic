import Foundation
import Testing

@testable import PickPic

struct StorageHeadroomServiceTests {
    // APIClient hits the network for anything beyond this guard, and wiring
    // a fake response back in requires the protocol/DI seam issue #136
    // explicitly puts out of scope. A job with nothing left to convert
    // returns nil before ever awaiting client.fetchStorageUsage(), which
    // this exercises safely with a client pointed at an address that would
    // fail (rather than silently pass) if that guard ever regressed.
    private static func makeUnreachableClient() -> APIClient {
        APIClient(
            baseURL: URL(string: "https://pickpic-tests.invalid")!,
            credential: SessionCredential(
                token: "test",
                expiresAt: Date.distantFuture
            )
        )
    }

    @Test
    func returnsNilWithNothingLeftToConvert() async {
        let job = UploadJob(
            id: UUID(),
            eventID: "evt-1",
            eventTitle: "Empty Event",
            folderName: "Folder",
            folderBookmarkData: Data(),
            photos: [],
            stage: .queued,
            createdAt: Date(),
            updatedAt: Date()
        )

        let message = await StorageHeadroomService.warningMessage(
            for: job,
            client: Self.makeUnreachableClient()
        )

        #expect(message == nil)
    }
}
