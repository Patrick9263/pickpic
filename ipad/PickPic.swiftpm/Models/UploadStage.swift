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
}
