import Foundation

enum ContinuedProcessingOperation:
    String,
    Codable,
    Hashable,
    Sendable
{
    case prepareConvertAndUpload
    case reconvertOnly
}

enum ContinuedProcessingStatus:
    String,
    Codable,
    Hashable,
    Sendable
{
    case scheduled
    case active
    case deferred
    case foregroundFallback
}

struct ContinuedProcessingState:
    Codable,
    Hashable,
    Sendable
{
    let identifier: String
    let operation: ContinuedProcessingOperation
    let requestedAt: Date

    var status: ContinuedProcessingStatus
    var startedAt: Date?
    var endedAt: Date?
    var message: String?

    var isScheduledOrActive: Bool {
        status == .scheduled || status == .active
    }
}
