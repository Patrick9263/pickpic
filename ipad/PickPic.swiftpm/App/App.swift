import SwiftUI

@main
struct PickPicApp: App {
    @StateObject private var uploadQueue =
    UploadQueueStore()
    
    @StateObject private var eventFolders =
    EventFolderStore()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(uploadQueue)
                .environmentObject(eventFolders)
        }
    }
}
