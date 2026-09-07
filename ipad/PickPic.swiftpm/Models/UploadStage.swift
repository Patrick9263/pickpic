import Foundation

enum UploadStage:
    String,
    Codable,
    Hashable,
    Sendable
{
    case queued
    case preparing
    case prepared
    case preflighting
    case converting
    case readyToUpload
    case uploading
    case completed
    case failed
    
    var title: String {
        switch self {
        case .queued:
            return "Queued"
            
        case .preparing:
            return "Preparing"
            
        case .prepared:
            return "Ready to Convert"

        case .preflighting:
            return "Checking for Duplicates"

        case .converting:
            return "Converting"
            
        case .readyToUpload:
            return "Ready to Upload"
            
        case .uploading:
            return "Uploading"
            
        case .completed:
            return "Completed"
            
        case .failed:
            return "Failed"
        }
    }
    
    var systemImage: String {
        switch self {
        case .queued:
            return "clock"
            
        case .preparing:
            return "folder.badge.gearshape"
            
        case .prepared:
            return "checkmark.circle"
            
        case .preflighting:
            return "doc.on.doc"

        case .converting:
            return "photo.badge.arrow.down"
            
        case .readyToUpload:
            return "tray.and.arrow.up.fill"
            
        case .uploading:
            return "arrow.up.circle"
            
        case .completed:
            return "checkmark.circle.fill"
            
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    var isActiveOperation: Bool {
        switch self {
        case .preparing,
                .preflighting,
                .converting,
                .uploading:
            return true

        case .queued,
                .prepared,
                .readyToUpload,
                .completed,
                .failed:
            return false
        }
    }

    /*
     * A job can only be reconverted once it has something to convert:
     * prepared photos, or a batch that already made it all the way to
     * readyToUpload. A job still queued or failed hasn't been prepared
     * yet, so there's nothing here to redo.
     */
    var isReconvertible: Bool {
        switch self {
        case .prepared,
                .readyToUpload:
            return true

        case .queued,
                .preparing,
                .preflighting,
                .converting,
                .uploading,
                .completed,
                .failed:
            return false
        }
    }

    /*
     * A job can enter preparation from its two "not yet prepared" resting
     * states. Every other stage has either already been prepared or is
     * mid-operation, so re-preparing it would restart work in progress
     * or redo work that already succeeded.
     */
    var isPreparable: Bool {
        switch self {
        case .queued,
                .failed:
            return true

        case .preparing,
                .prepared,
                .preflighting,
                .converting,
                .readyToUpload,
                .uploading,
                .completed:
            return false
        }
    }
}
