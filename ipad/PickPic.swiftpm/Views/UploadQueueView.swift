import SwiftUI

struct UploadQueueView: View {
    var body: some View {
        ContentUnavailableView(
            "Upload Queue Is Empty",
            systemImage: "arrow.up.circle",
            description: Text(
                "Photos waiting, uploading, or needing attention will appear here."
            )
        )
        .navigationTitle("Upload Queue")
        .navigationBarTitleDisplayMode(.inline)
    }
}
