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
    
    init(
        eventID: String,
        folderName: String,
        bookmarkData: Data,
        updatedAt: Date
    ) {
        self.eventID = eventID
        self.folderName = folderName
        self.bookmarkData = bookmarkData
        self.updatedAt = updatedAt
    }
    
    private enum CodingKeys:
        String,
        CodingKey
    {
        case eventID
        case folderName
        case bookmarkData
        case updatedAt
    }
    
    /*
     * Hand-written for the same reason UploadJob's decoder is (CLAUDE.md
     * trap 1), and under the same contract: the four fields that shipped
     * originally decode strictly, and *every field added after this point
     * must use decodeIfPresent with a default* so an event-folders.json
     * written by an older build keeps decoding.
     *
     * The stakes here are higher than they look. bookmarkData is a
     * security-scoped bookmark the user granted through the document
     * picker; it cannot be regenerated from anything the app holds. A
     * field addition that made existing entries fail to decode would cost
     * the operator a manual re-pick of every event folder on the device.
     */
    init(
        from decoder: Decoder
    ) throws {
        let container =
        try decoder.container(
            keyedBy: CodingKeys.self
        )
        
        eventID = try container.decode(
            String.self,
            forKey: .eventID
        )
        
        folderName = try container.decode(
            String.self,
            forKey: .folderName
        )
        
        bookmarkData = try container.decode(
            Data.self,
            forKey: .bookmarkData
        )
        
        updatedAt = try container.decode(
            Date.self,
            forKey: .updatedAt
        )
    }
}
