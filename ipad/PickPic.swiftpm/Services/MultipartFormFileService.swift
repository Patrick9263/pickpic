import Foundation

struct MultipartUploadBody: Sendable {
    let fileURL: URL
    let boundary: String
}

enum MultipartFormFileService {
    private static let chunkSize =
    1 * 1_024 * 1_024
    
    static func createFinalVariantsBody(
        photoID: String,
        variants: GeneratedFinalVariants
    ) throws -> MultipartUploadBody {
        let boundary =
        "PickPic-\(UUID().uuidString)"
        
        let directoryURL =
        multipartDirectoryURL()
        
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        
        let bodyURL =
        directoryURL.appendingPathComponent(
            "\(photoID)-\(UUID().uuidString).multipart",
            isDirectory: false
        )
        
        guard FileManager.default.createFile(
            atPath: bodyURL.path,
            contents: nil
        ) else {
            throw CocoaError(
                .fileWriteUnknown
            )
        }
        
        let output =
        try FileHandle(
            forWritingTo: bodyURL
        )
        
        do {
            try appendTextField(
                name: "thumbnailWidth",
                value:
                    String(
                        variants
                            .thumbnail
                            .pixelWidth
                    ),
                boundary: boundary,
                to: output
            )
            
            try appendTextField(
                name: "thumbnailHeight",
                value:
                    String(
                        variants
                            .thumbnail
                            .pixelHeight
                    ),
                boundary: boundary,
                to: output
            )
            
            try appendTextField(
                name: "previewWidth",
                value:
                    String(
                        variants
                            .preview
                            .pixelWidth
                    ),
                boundary: boundary,
                to: output
            )
            
            try appendTextField(
                name: "previewHeight",
                value:
                    String(
                        variants
                            .preview
                            .pixelHeight
                    ),
                boundary: boundary,
                to: output
            )
            
            try appendFile(
                fieldName: "thumbnail",
                filename: "thumbnail.jpg",
                fileURL:
                    variants.thumbnail.fileURL,
                boundary: boundary,
                to: output
            )
            
            try appendFile(
                fieldName: "preview",
                filename: "preview.jpg",
                fileURL:
                    variants.preview.fileURL,
                boundary: boundary,
                to: output
            )
            
            try write(
                "--\(boundary)--\r\n",
                to: output
            )
            
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(
                at: bodyURL
            )
            
            throw error
        }
        
        return MultipartUploadBody(
            fileURL: bodyURL,
            boundary: boundary
        )
    }
    
    static func remove(
        _ body: MultipartUploadBody
    ) throws {
        guard FileManager.default.fileExists(
            atPath: body.fileURL.path
        ) else {
            return
        }
        
        try FileManager.default.removeItem(
            at: body.fileURL
        )
    }
    
    private static func appendTextField(
        name: String,
        value: String,
        boundary: String,
        to output: FileHandle
    ) throws {
        try write(
            """
            --\(boundary)\r
            Content-Disposition: form-data; name="\(name)"\r
            \r
            \(value)\r
            
            """,
            to: output
        )
    }
    
    private static func appendFile(
        fieldName: String,
        filename: String,
        fileURL: URL,
        boundary: String,
        to output: FileHandle
    ) throws {
        try write(
            """
            --\(boundary)\r
            Content-Disposition: form-data; name="\(fieldName)"; filename="\(filename)"\r
            Content-Type: image/jpeg\r
            \r
            
            """,
            to: output
        )
        
        let input =
        try FileHandle(
            forReadingFrom: fileURL
        )
        
        defer {
            try? input.close()
        }
        
        while true {
            let data =
            try input.read(
                upToCount: chunkSize
            )
            ?? Data()
            
            guard !data.isEmpty else {
                break
            }
            
            try output.write(
                contentsOf: data
            )
        }
        
        try write(
            "\r\n",
            to: output
        )
    }
    
    private static func write(
        _ value: String,
        to output: FileHandle
    ) throws {
        try output.write(
            contentsOf: Data(
                value.utf8
            )
        )
    }
    
    private static func multipartDirectoryURL()
    -> URL
    {
        AppStorageService.multipartUploadsURL
    }
}
