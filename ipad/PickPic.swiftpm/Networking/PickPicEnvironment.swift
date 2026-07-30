import Foundation

enum PickPicEnvironment {
    static let publicAppBaseURL = URL(
        string:
            "https://pickpic.photos"
    )!
    
    static func galleryURL(
        shareToken: String
    ) -> URL {
        publicAppBaseURL
            .appending(path: "g")
            .appending(path: shareToken)
    }
}
