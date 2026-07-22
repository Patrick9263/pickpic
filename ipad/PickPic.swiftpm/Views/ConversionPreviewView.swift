import SwiftUI
import UIKit

struct ConversionPreviewView: View {
    let job: UploadJob
    
    @State private var image: UIImage?
    @State private var imageLoadFailed = false
    
    private var preview: ConversionPreview? {
        job.conversionPreview
    }
    
    var body: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: 18
            ) {
                previewImage
                
                if let preview {
                    GroupBox("Conversion Details") {
                        VStack(
                            alignment: .leading,
                            spacing: 12
                        ) {
                            LabeledContent(
                                "Source",
                                value:
                                    preview.sourceFilename
                            )
                            
                            LabeledContent(
                                "Dimensions",
                                value:
                                    """
                                    \(preview.pixelWidth) × \
                                    \(preview.pixelHeight)
                                    """
                            )
                            
                            LabeledContent(
                                "JPEG size",
                                value:
                                    ByteCountFormatter.string(
                                        fromByteCount:
                                            preview.byteSize,
                                        countStyle: .file
                                    )
                            )
                            
                            LabeledContent(
                                "Converted",
                                value:
                                    preview.convertedAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Test Preview")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: preview?.convertedAt) {
            loadImage()
        }
    }
    
    @ViewBuilder
    private var previewImage: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 12
                    )
                )
        } else if imageLoadFailed {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage:
                    "exclamationmark.triangle",
                description: Text(
                    """
                    The converted JPEG could not \
                    be opened.
                    """
                )
            )
        } else {
            ProgressView("Loading preview…")
                .frame(
                    maxWidth: .infinity,
                    minHeight: 250
                )
        }
    }
    
    private func loadImage() {
        guard let preview else {
            imageLoadFailed = true
            return
        }
        
        let imageURL =
        ImageConversionService.previewURL(
            jobID: job.id,
            outputFilename:
                preview.outputFilename
        )
        
        image = UIImage(
            contentsOfFile: imageURL.path
        )
        
        imageLoadFailed = image == nil
    }
}
