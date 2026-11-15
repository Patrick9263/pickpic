import SwiftUI

/*
 * Shows a photo's gallery comments wherever the photographer is working
 * from a list of server photos. A comment is usually the detail of an
 * edit request ("can you brighten her face?"), and the photographer is
 * typically dragging the RAW into an editor beside PickPic at the time,
 * so the thread opens in a popover anchored to the row rather than
 * navigating away from the list.
 *
 * Renders nothing for a photo without comments.
 */
struct PhotoCommentsButton: View {
    enum Style {
        // The latest comment inline, for the screen edits start from.
        case preview

        // Just a count, for screens where comments are secondary.
        case badge
    }

    let photo: ServerPhotoRecord
    let style: Style

    @State private var isShowingThread = false

    private var comments: [ServerPhotoComment] {
        photo.photoComments
    }

    var body: some View {
        if let latest = comments.last {
            Button {
                isShowingThread = true
            } label: {
                switch style {
                case .preview:
                    previewLabel(latest: latest)

                case .badge:
                    badgeLabel
                }
            }
            /*
             * Borderless so the button takes the tap without a row's drag
             * gesture swallowing it.
             */
            .buttonStyle(.borderless)
            .popover(isPresented: $isShowingThread) {
                PhotoCommentThread(
                    filename: photo.originalFilename,
                    comments: comments
                )
                /*
                 * PickPic usually runs in Split View beside the editor,
                 * which is a compact width; adapting to a sheet there
                 * would cover the very list the photographer is dragging
                 * from.
                 */
                .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel(
                comments.count == 1
                    ? "1 comment on \(photo.originalFilename)"
                    : "\(comments.count) comments on \(photo.originalFilename)"
            )
            .accessibilityHint("Shows the comments")
        }
    }

    private func previewLabel(
        latest: ServerPhotoComment
    ) -> some View {
        HStack(
            alignment: .firstTextBaseline,
            spacing: 6
        ) {
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(.tint)

            Text(
                "\(Text(latest.displayName).fontWeight(.semibold)): \(latest.body)"
            )
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)

            if comments.count > 1 {
                Text("+\(comments.count - 1)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var badgeLabel: some View {
        Label(
            "\(comments.count)",
            systemImage: "text.bubble.fill"
        )
        .font(.subheadline)
        .labelStyle(.titleAndIcon)
    }
}

private struct PhotoCommentThread: View {
    let filename: String
    let comments: [ServerPhotoComment]

    var body: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: 14
            ) {
                Text(filename)
                    .font(.headline)

                ForEach(comments) { comment in
                    VStack(
                        alignment: .leading,
                        spacing: 4
                    ) {
                        HStack(
                            alignment: .firstTextBaseline
                        ) {
                            Text(comment.displayName)
                                .fontWeight(.semibold)

                            Spacer()

                            if let date = comment.createdAtDate {
                                Text(
                                    date.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)

                        /*
                         * Selectable so a request can be copied into the
                         * editor or a note instead of retyped.
                         */
                        Text(comment.body)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
        .frame(
            minWidth: 320,
            idealWidth: 380,
            maxWidth: 440,
            maxHeight: 480
        )
    }
}
