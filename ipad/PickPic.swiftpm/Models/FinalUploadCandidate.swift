import Foundation

struct FinalUploadCandidate:
    Identifiable,
    Hashable,
    Sendable
{
    let photoID: String
    let sourceFilename: String
    let editedFilename: String
    let byteSize: Int64
    let isReplacement: Bool
    
    var id: String {
        photoID
    }
}

struct FinalUploadScanResult:
    Hashable,
    Sendable
{
    let eligiblePhotoCount: Int
    let candidates: [FinalUploadCandidate]
    
    let missingSourceFilenames: [String]
    let unmatchedEditedFilenames: [String]
    let ambiguousMatches: [String]
    let oversizedEditedFilenames: [String]
}
