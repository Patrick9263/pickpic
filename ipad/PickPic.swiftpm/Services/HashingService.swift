import CryptoKit
import Foundation

enum HashingServiceError: LocalizedError {
    case fileUnavailable(String)
    
    var errorDescription: String? {
        switch self {
        case let .fileUnavailable(filename):
            return """
            PickPic could not open \(filename) for duplicate detection.
            """
        }
    }
}

enum HashingService {
    private static let chunkSize =
    4 * 1_024 * 1_024
    
    static func sha256Hex(
        for fileURL: URL
    ) throws -> String {
        guard
            FileManager.default.fileExists(
                atPath: fileURL.path
            )
        else {
            throw HashingServiceError
                .fileUnavailable(
                    fileURL.lastPathComponent
                )
        }
        
        let fileHandle = try FileHandle(
            forReadingFrom: fileURL
        )
        
        defer {
            try? fileHandle.close()
        }
        
        var hasher = SHA256()
        
        while true {
            let data =
            try fileHandle.read(
                upToCount: chunkSize
            )
            ?? Data()
            
            guard !data.isEmpty else {
                break
            }
            
            hasher.update(data: data)
        }
        
        let digest = hasher.finalize()
        
        return digest.map { byte in
            String(
                format: "%02x",
                byte
            )
        }
        .joined()
    }
}
