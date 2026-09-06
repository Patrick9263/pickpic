import Foundation
import Testing

@testable import PickPic

struct PhotoMetadataServiceTests {
    // PhotoMetadataService's EXIF/GPS parsing lives in private helpers, and
    // #136 explicitly rules out production changes to expose them, so this
    // covers only the public API's failure path: anything
    // CGImageSourceCreateWithURL can't open comes back as .empty rather
    // than throwing or crashing. Positive-case coverage (a real image with
    // EXIF/GPS metadata) would need a fixture-image helper and is a
    // reasonable follow-up, not part of this first slice.
    @Test
    func missingFileReturnsEmptyMetadata() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-does-not-exist.jpg")

        let metadata = PhotoMetadataService.extract(from: url)

        #expect(metadata == .empty)
    }

    @Test
    func nonImageFileReturnsEmptyMetadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).jpg")
        try Data("not actually a jpeg".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = PhotoMetadataService.extract(from: url)

        #expect(metadata == .empty)
    }
}
