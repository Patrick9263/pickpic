import Foundation

struct SourcePhoto: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case raw
        case jpeg
        
        var title: String {
            switch self {
            case .raw:
                return "RAW"
                
            case .jpeg:
                return "JPEG"
            }
        }
        
        var systemImage: String {
            switch self {
            case .raw:
                return "camera.aperture"
                
            case .jpeg:
                return "photo"
            }
        }
    }
    
    let filename: String
    let byteSize: Int64
    let kind: Kind
    
    var id: String {
        filename
    }
}
