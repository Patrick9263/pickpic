import Foundation

struct ResolvedFolderBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

enum FolderBookmarkService {
    static func resolve(
        _ bookmarkData: Data
    ) throws -> ResolvedFolderBookmark {
        var isStale = false
        
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        
        return ResolvedFolderBookmark(
            url: url,
            isStale: isStale
        )
    }
    
    static func canAccessFolder(
        using bookmarkData: Data
    ) -> Bool {
        do {
            let resolved = try resolve(bookmarkData)
            
            let accessed =
            resolved.url
                .startAccessingSecurityScopedResource()
            
            guard accessed else {
                return false
            }
            
            defer {
                resolved.url
                    .stopAccessingSecurityScopedResource()
            }
            
            var isDirectory: ObjCBool = false
            
            let exists = FileManager.default.fileExists(
                atPath: resolved.url.path,
                isDirectory: &isDirectory
            )
            
            return exists && isDirectory.boolValue
        } catch {
            return false
        }
    }
}
