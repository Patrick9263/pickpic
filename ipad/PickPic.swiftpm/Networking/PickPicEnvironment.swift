import Foundation

enum PickPicEnvironment {
    static let publicAppBaseURL = URL(
        string:
            "https://pickpic.maverickthedeer.workers.dev"
    )!
    
    static func galleryURL(
        shareToken: String
    ) -> URL {
        publicAppBaseURL
            .appending(path: "g")
            .appending(path: shareToken)
    }
}
