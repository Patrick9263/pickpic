import Foundation

struct EventFolderReference:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    let eventID: String
    let folderName: String
    let bookmarkData: Data
    let updatedAt: Date
    
    var id: String {
        eventID
    }
}
