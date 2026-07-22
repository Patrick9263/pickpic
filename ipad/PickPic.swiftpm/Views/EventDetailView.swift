import SwiftUI

struct EventDetailView: View {
    let event: PickPicEvent
    
    var body: some View {
        List {
            Section("Event") {
                LabeledContent("Name", value: event.title)
                
                LabeledContent {
                    Label(
                        event.status.title,
                        systemImage: event.status.systemImage
                    )
                } label: {
                    Text("Status")
                }
                
                LabeledContent(
                    "Created",
                    value: event.createdAt.formatted(
                        date: .long,
                        time: .shortened
                    )
                )
                
                LabeledContent(
                    "Updated",
                    value: event.updatedAt.formatted(
                        date: .long,
                        time: .shortened
                    )
                )
            }
            
            Section("Photos") {
                NavigationLink {
                    PhotoImportView(event: event)
                } label: {
                    Label(
                        "Import Photos",
                        systemImage: "photo.badge.plus"
                    )
                }
                
                NavigationLink {
                    UploadQueueView()
                } label: {
                    Label("Upload Queue", systemImage: "arrow.up.circle")
                }
            }
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
