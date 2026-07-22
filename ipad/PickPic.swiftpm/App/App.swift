import SwiftUI

@main
struct PickPicApp: App {
    @StateObject private var uploadQueue =
    UploadQueueStore()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(uploadQueue)
        }
    }
}
