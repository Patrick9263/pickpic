import CryptoKit
import Foundation
import Testing

@testable import PickPic

struct HashingServiceTests {
    private func writeFixture(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    @Test
    func knownEmptyFileHashesToTheStandardSHA256OfEmptyInput() throws {
        let url = try writeFixture(Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let hex = try HashingService.sha256Hex(for: url)

        #expect(
            hex
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test
    func knownContentHashesToItsPublishedSHA256() throws {
        let url = try writeFixture(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let hex = try HashingService.sha256Hex(for: url)

        #expect(
            hex
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test
    func multiChunkFileMatchesAWholeFileDigest() throws {
        // Larger than HashingService's private 4 MB chunk size, so this
        // exercises the multi-read loop rather than a single read call.
        let data = Data(repeating: 0x5A, count: 5 * 1_024 * 1_024 + 17)
        let url = try writeFixture(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let hex = try HashingService.sha256Hex(for: url)
        let expected = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(hex == expected)
    }

    @Test
    func missingFileThrowsFileUnavailable() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-does-not-exist.bin")

        #expect(throws: HashingServiceError.self) {
            try HashingService.sha256Hex(for: url)
        }
    }
}
