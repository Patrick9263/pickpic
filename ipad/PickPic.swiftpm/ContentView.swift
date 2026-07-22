import SwiftUI

struct ContentView: View {
    private let events = PickPicEvent.previewEvents
    
    var body: some View {
        NavigationStack {
            EventListView(events: events)
        }
    }
}
