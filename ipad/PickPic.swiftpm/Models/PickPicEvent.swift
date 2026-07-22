import Foundation

struct PickPicEvent: Identifiable, Hashable, Codable {
    enum Status: String, Codable, CaseIterable {
        case draft
        case ready
        case completed
        case archived
        
        var title: String {
            switch self {
            case .draft:
                return "Draft"
            case .ready:
                return "Ready"
            case .completed:
                return "Completed"
            case .archived:
                return "Archived"
            }
        }
        
        var systemImage: String {
            switch self {
            case .draft:
                return "pencil"
            case .ready:
                return "checkmark.circle"
            case .completed:
                return "checkmark.seal"
            case .archived:
                return "archivebox"
            }
        }
    }
    
    let id: String
    let title: String
    let shareToken: String
    let status: Status
    let createdAt: Date
    let updatedAt: Date
}

extension PickPicEvent {
    static let previewEvents: [PickPicEvent] = [
        PickPicEvent(
            id: "preview-boston",
            title: "Boston Photo Walk",
            shareToken: "preview-boston-token",
            status: .ready,
            createdAt: .now.addingTimeInterval(-172_800),
            updatedAt: .now.addingTimeInterval(-3_600)
        ),
        PickPicEvent(
            id: "preview-test",
            title: "PickPic Test Event",
            shareToken: "preview-test-token",
            status: .draft,
            createdAt: .now.addingTimeInterval(-86_400),
            updatedAt: .now.addingTimeInterval(-7_200)
        )
    ]
}
