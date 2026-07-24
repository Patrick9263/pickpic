import SwiftUI
import UIKit

@main
struct PickPicApp: App {
    @StateObject private var uploadQueue =
    UploadQueueStore()
    
    @StateObject private var eventFolders =
    EventFolderStore()
    
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(uploadQueue)
                .environmentObject(eventFolders)
                .task {
                    await uploadQueue
                        .performStorageMaintenance()
                }
                .onAppear {
                    updateIdleTimer(
                        for: uploadQueue.jobs
                    )
                }
                .onReceive(
                    uploadQueue.$jobs
                ) { jobs in
                    updateIdleTimer(
                        for: jobs
                    )
                }
                .onChange(
                    of: scenePhase
                ) { _, newPhase in
                    switch newPhase {
                    case .active:
                        updateIdleTimer(
                            for: uploadQueue.jobs
                        )
                        
                    case .inactive,
                            .background:
                        UIApplication.shared
                            .isIdleTimerDisabled = false
                        
                    @unknown default:
                        UIApplication.shared
                            .isIdleTimerDisabled = false
                    }
                }
        }
    }
    
    private func updateIdleTimer(
        for jobs: [UploadJob]
    ) {
        let hasActiveProcessing =
        jobs.contains { job in
            switch job.stage {
            case .preparing,
                    .converting,
                    .uploading:
                return true
                
            case .queued,
                    .prepared,
                    .readyToUpload,
                    .completed,
                    .failed:
                return false
            }
        }
        
        UIApplication.shared.isIdleTimerDisabled =
        hasActiveProcessing
    }
}
