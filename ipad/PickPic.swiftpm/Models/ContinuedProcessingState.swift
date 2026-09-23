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

    /*
     * The one gate between a submitted request and whoever runs it. A
     * job leaves .scheduled exactly once -- promoted to .active by the
     * iPadOS launch handler, or to .foregroundFallback by a failed
     * submission or the launch deadline -- and both paths check this
     * first, on the main actor, with no suspension between the check and
     * the status write. So whichever arrives second sees the job already
     * claimed: a launch that turns up after the foreground run started is
     * dismissed rather than running the same job twice.
     */
    func isAwaitingLaunch(
        identifier: String,
        operation: ContinuedProcessingOperation
    ) -> Bool {
        status == .scheduled
            && self.identifier == identifier
            && self.operation == operation
    }
}
