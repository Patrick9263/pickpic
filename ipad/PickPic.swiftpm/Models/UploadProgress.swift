import Foundation

enum UploadOperationStep:
    String,
    Codable,
    Hashable,
    Sendable
{
    case proofUpload
    case variantGeneration
    case variantUpload

    var title: String {
        switch self {
        case .proofUpload:
            return "Uploading proof JPEG"

        case .variantGeneration:
            return "Creating thumbnail and preview"

        case .variantUpload:
            return "Uploading thumbnail and preview"
        }
    }
}

struct UploadFailure:
    Codable,
    Hashable,
    Sendable
{
    let sourceFilename: String
    let step: UploadOperationStep
    let message: String
    let occurredAt: Date
    let isNetworkRelated: Bool
}

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

    // Optional so upload queues saved by older PickPic builds continue
    // decoding without a migration.
    var currentStep: UploadOperationStep? = nil
    var lastFailure: UploadFailure? = nil
    var pauseRequested: Bool? = nil
    var pausedAt: Date? = nil

    var isPauseRequested: Bool {
        pauseRequested == true
    }

    var isPaused: Bool {
        pausedAt != nil
    }

    static let empty = UploadProgress(
        completedSourceFilenames: [],
        duplicateSourceFilenames: [],
        currentFilename: nil,
        startedAt: nil,
        completedAt: nil,
        errorMessage: nil
    )
}
