import SwiftUI

struct EventDetailView: View {
    @State private var event:
    PickPicEvent
    
    let onEventUpdated:
    (PickPicEvent) -> Void
    
    init(
        event: PickPicEvent,
        onEventUpdated:
        @escaping (PickPicEvent) -> Void
    ) {
        _event = State(
            initialValue: event
        )
        
        self.onEventUpdated =
        onEventUpdated
    }
    
    var body: some View {
        List {
            Section("Event") {
                LabeledContent(
                    "Name",
                    value: event.title
                )
                
                LabeledContent {
                    Label(
                        event.status.title,
                        systemImage:
                            event.status.systemImage
                    )
                } label: {
                    Text("Status")
                }
                
                LabeledContent(
                    "Created",
                    value:
                        event.createdAt.formatted(
                            date: .long,
                            time: .shortened
                        )
                )
                
                LabeledContent(
                    "Updated",
                    value:
                        event.updatedAt.formatted(
                            date: .long,
                            time: .shortened
                        )
                )
            }
            
            Section("Photos") {
                NavigationLink {
                    PhotoImportView(
                        event: event
                    )
                } label: {
                    Label(
                        "Import Photos",
                        systemImage:
                            "photo.badge.plus"
                    )
                }
                
                NavigationLink {
                    UploadQueueView(
                        event: event
                    )
                } label: {
                    Label(
                        "Upload Queue",
                        systemImage:
                            "arrow.up.circle"
                    )
                }
                
                NavigationLink {
                    LikedPhotosView(event: event)
                } label: {
                    Label(
                        "Liked Photos",
                        systemImage: "heart.fill"
                    )
                }
                
                NavigationLink {
                    FinalUploadsView(event: event)
                } label: {
                    Label(
                        "Upload Finals",
                        systemImage:
                            "arrow.up.circle.fill"
                    )
                }
            }
            
            Section("Gallery") {
                NavigationLink {
                    PublishGalleryView(
                        event: event
                    ) { updatedEvent in
                        event = updatedEvent
                        
                        onEventUpdated(
                            updatedEvent
                        )
                    }
                } label: {
                    Label(
                        "Publish & Share",
                        systemImage:
                            "square.and.arrow.up"
                    )
                }
            }
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
