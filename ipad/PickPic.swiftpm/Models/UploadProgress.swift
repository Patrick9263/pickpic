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
    var optimizedSourceFilenames: Set<String>

    var currentFilename: String?

    var startedAt: Date?
    var completedAt: Date?

    var errorMessage: String?

    var currentStep: UploadOperationStep?
    var lastFailure: UploadFailure?
    var pauseRequested: Bool?
    var pausedAt: Date?

    // Tracks active upload time without counting time spent paused or
    // waiting between app launches. Optional values from older queues
    // are migrated to zero during decoding.
    var activeUploadDuration: TimeInterval
    var currentRunStartedAt: Date?

    var isPauseRequested: Bool {
        pauseRequested == true
    }

    var isPaused: Bool {
        pausedAt != nil
    }

    init(
        completedSourceFilenames: Set<String>,
        duplicateSourceFilenames: Set<String>,
        currentFilename: String?,
        startedAt: Date?,
        completedAt: Date?,
        errorMessage: String?,
        currentStep: UploadOperationStep? = nil,
        lastFailure: UploadFailure? = nil,
        pauseRequested: Bool? = nil,
        pausedAt: Date? = nil,
        optimizedSourceFilenames: Set<String> = [],
        activeUploadDuration: TimeInterval = 0,
        currentRunStartedAt: Date? = nil
    ) {
        self.completedSourceFilenames =
        completedSourceFilenames
        self.duplicateSourceFilenames =
        duplicateSourceFilenames
        self.optimizedSourceFilenames =
        optimizedSourceFilenames
        self.currentFilename = currentFilename
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.currentStep = currentStep
        self.lastFailure = lastFailure
        self.pauseRequested = pauseRequested
        self.pausedAt = pausedAt
        self.activeUploadDuration =
        activeUploadDuration
        self.currentRunStartedAt =
        currentRunStartedAt
    }

    func activeDuration(
        at date: Date
    ) -> TimeInterval {
        let currentRunDuration: TimeInterval

        if let currentRunStartedAt {
            currentRunDuration = max(
                date.timeIntervalSince(
                    currentRunStartedAt
                ),
                0
            )
        } else {
            currentRunDuration = 0
        }

        return max(
            activeUploadDuration
                + currentRunDuration,
            0
        )
    }

    static let empty = UploadProgress(
        completedSourceFilenames: [],
        duplicateSourceFilenames: [],
        currentFilename: nil,
        startedAt: nil,
        completedAt: nil,
        errorMessage: nil
    )

    private enum CodingKeys:
        String,
        CodingKey
    {
        case completedSourceFilenames
        case duplicateSourceFilenames
        case optimizedSourceFilenames
        case currentFilename
        case startedAt
        case completedAt
        case errorMessage
        case currentStep
        case lastFailure
        case pauseRequested
        case pausedAt
        case activeUploadDuration
        case currentRunStartedAt
    }

    init(
        from decoder: Decoder
    ) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        completedSourceFilenames =
        try container.decodeIfPresent(
            Set<String>.self,
            forKey:
                .completedSourceFilenames
        )
        ?? []

        duplicateSourceFilenames =
        try container.decodeIfPresent(
            Set<String>.self,
            forKey:
                .duplicateSourceFilenames
        )
        ?? []

        optimizedSourceFilenames =
        try container.decodeIfPresent(
            Set<String>.self,
            forKey:
                .optimizedSourceFilenames
        )
        ?? []

        currentFilename =
        try container.decodeIfPresent(
            String.self,
            forKey: .currentFilename
        )

        startedAt =
        try container.decodeIfPresent(
            Date.self,
            forKey: .startedAt
        )

        completedAt =
        try container.decodeIfPresent(
            Date.self,
            forKey: .completedAt
        )

        errorMessage =
        try container.decodeIfPresent(
            String.self,
            forKey: .errorMessage
        )

        currentStep =
        try container.decodeIfPresent(
            UploadOperationStep.self,
            forKey: .currentStep
        )

        lastFailure =
        try container.decodeIfPresent(
            UploadFailure.self,
            forKey: .lastFailure
        )

        pauseRequested =
        try container.decodeIfPresent(
            Bool.self,
            forKey: .pauseRequested
        )

        pausedAt =
        try container.decodeIfPresent(
            Date.self,
            forKey: .pausedAt
        )

        activeUploadDuration =
        try container.decodeIfPresent(
            TimeInterval.self,
            forKey:
                .activeUploadDuration
        )
        ?? 0

        currentRunStartedAt =
        try container.decodeIfPresent(
            Date.self,
            forKey:
                .currentRunStartedAt
        )
    }
}
