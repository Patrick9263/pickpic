import Foundation

struct UploadProgress:
    Codable,
    Hashable,
    Sendable
{
    var completedSourceFilenames: Set<String>
    var duplicateSourceFilenames: Set<String>
    
    var currentFilename: String?
    
    var startedAt: Date?
    var completedAt: Date?
    
    var errorMessage: String?
    
    static let empty = UploadProgress(
        completedSourceFilenames: [],
        duplicateSourceFilenames: [],
        currentFilename: nil,
        startedAt: nil,
        completedAt: nil,
        errorMessage: nil
    )
}
