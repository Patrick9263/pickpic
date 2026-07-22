import Foundation

enum UploadStage:
    String,
    Codable,
    Hashable,
    Sendable
{
    case queued
    case preparing
    case converting
    case uploading
    case completed
    case failed
    
    var title: String {
        switch self {
        case .queued:
            return "Queued"
            
        case .preparing:
            return "Preparing"
            
        case .converting:
            return "Converting"
            
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
            
        case .converting:
            return "photo.badge.arrow.down"
            
        case .uploading:
            return "arrow.up.circle"
            
        case .completed:
            return "checkmark.circle"
            
        case .failed:
            return "exclamationmark.triangle"
        }
    }
}
