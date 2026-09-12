import Foundation

struct StagedRawUpload: Sendable {
    let photoID: String
    let fileURL: URL
    let filename: String
    let sha256: String
    let byteSize: Int64
}

enum RawUploadFileError: LocalizedError {
    case eventFolderUnavailable
    case invalidFilename(String)
    case fileMissing(String)
    case fileTooLarge(String, Int64)

    var errorDescription: String? {
        switch self {
        case .eventFolderUnavailable:
            return """
            PickPic could not access the saved event folder.
            """

        case let .invalidFilename(filename):
            return """
            The server returned an unsafe source filename: \
            \(filename).
            """

        case let .fileMissing(filename):
            return """
            \(filename) is no longer in the event folder or in \
            To Edit, so its RAW file could not be sent.
            """

        case let .fileTooLarge(filename, byteSize):
            let formattedSize =
            ByteCountFormatter.string(
                fromByteCount: byteSize,
                countStyle: .file
            )
            let formattedLimit =
            ByteCountFormatter.string(
                fromByteCount: RawUploadFileService.maximumRawBytes,
                countStyle: .file
            )

            return """
            \(filename) is \(formattedSize). RAW files must be \
            \(formattedLimit) or smaller.
            """
        }
    }
}

/*
 * Stages the original RAW for a photo a gallery viewer has asked for, so it
 * can be uploaded (issue #205). Mirrors FinalUploadFileService, which does the
 * same job for a delivered edit.
 */
enum RawUploadFileService {
    /*
     * Must stay equal to MAX_RAW_BYTES in worker/index.ts, which is itself
     * pinned to Cloudflare's Free/Pro edge cap rather than set independently
     * (#215) -- checking it here as well as there is not redundant: a RAW is
     * large enough that finding out after the transfer costs minutes of the
     * photographer's connection, and an oversize body is rejected at the edge
     * before our own 413 can explain why.
     */
    static let maximumRawBytes: Int64 = 100 * 1_024 * 1_024

    /*
     * Both the filename and the photo id arrive from the server and both are
     * appended to a URL, so both are treated as untrusted: anything carrying
     * a path separator, or either directory entry, would otherwise let a
     * response reach outside the folder it is supposed to name.
     */
    static func isSafePathComponent(
        _ value: String
    ) -> Bool {
        !value.isEmpty
        && value == (value as NSString)
            .lastPathComponent
        && value != "."
        && value != ".."
    }

    /*
     * The pure half of staging, split out so the rules can be tested without
     * a folder, a bookmark or a file on disk.
     */
    static func validate(
        filename: String,
        byteSize: Int64
    ) throws {
        guard isSafePathComponent(filename) else {
            throw RawUploadFileError
                .invalidFilename(filename)
        }

        guard byteSize <= maximumRawBytes else {
            throw RawUploadFileError
                .fileTooLarge(filename, byteSize)
        }
    }

    static func stage(
        photoID: String,
        filename: String,
        reference: EventFolderReference
    ) throws -> StagedRawUpload {
        guard isSafePathComponent(photoID) else {
            throw RawUploadFileError
                .invalidFilename(photoID)
        }

        /*
         * Checked before the folder is touched, so an unsafe name never
         * reaches appendingPathComponent. The size is unknown until the file
         * is found, so it is re-checked below with the real value.
         */
        try validate(
            filename: filename,
            byteSize: 0
        )

        let resolved = try FolderBookmarkService.resolve(
            reference.bookmarkData
        )

        let eventFolderURL = resolved.url

        guard
            eventFolderURL
                .startAccessingSecurityScopedResource()
        else {
            throw RawUploadFileError
                .eventFolderUnavailable
        }

        defer {
            eventFolderURL
                .stopAccessingSecurityScopedResource()
        }

        /*
         * To Edit first, and this order is not cosmetic. ToEditSyncService
         * *moves* a hearted photo's RAW into To Edit and deletes the source,
         * so a photo that was both hearted and RAW-requested exists nowhere
         * else — looking only in the event folder root would report the most
         * likely case of all as a missing original.
         */
        let candidateURLs = [
            eventFolderURL
                .appendingPathComponent(
                    UploadPreparationService
                        .toEditFolderName,
                    isDirectory: true
                )
                .appendingPathComponent(
                    filename,
                    isDirectory: false
                ),

            eventFolderURL
                .appendingPathComponent(
                    filename,
                    isDirectory: false
                )
        ]

        var located: (url: URL, byteSize: Int64)?

        for candidateURL in candidateURLs {
            guard
                let values = try? candidateURL
                    .resourceValues(
                        forKeys: [
                            .isRegularFileKey,
                            .fileSizeKey
                        ]
                    ),
                values.isRegularFile == true
            else {
                continue
            }

            located = (
                candidateURL,
                Int64(values.fileSize ?? 0)
            )

            break
        }

        guard let located else {
            throw RawUploadFileError
                .fileMissing(filename)
        }

        try validate(
            filename: filename,
            byteSize: located.byteSize
        )

        try AppStorageService
            .ensureRawUploadCapacity(
                rawByteSize: located.byteSize
            )

        let stagingDirectory =
        stagingDirectoryURL(photoID: photoID)

        if FileManager.default.fileExists(
            atPath: stagingDirectory.path
        ) {
            try FileManager.default.removeItem(
                at: stagingDirectory
            )
        }

        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )

        let stagedURL =
        stagingDirectory
            .appendingPathComponent(
                filename,
                isDirectory: false
            )

        try FileManager.default.copyItem(
            at: located.url,
            to: stagedURL
        )

        /*
         * Hashed from the staged copy rather than the source, so the value
         * describes the bytes that are actually going to be uploaded.
         */
        let sha256 =
        try HashingService.sha256Hex(
            for: stagedURL
        )

        return StagedRawUpload(
            photoID: photoID,
            fileURL: stagedURL,
            filename: filename,
            sha256: sha256,
            byteSize: located.byteSize
        )
    }

    static func removeStagedFile(
        photoID: String
    ) throws {
        let directoryURL =
        stagingDirectoryURL(photoID: photoID)

        guard FileManager.default.fileExists(
            atPath: directoryURL.path
        ) else {
            return
        }

        try FileManager.default.removeItem(
            at: directoryURL
        )
    }

    private static func stagingDirectoryURL(
        photoID: String
    ) -> URL {
        AppStorageService
            .rawUploadStagingURL
            .appendingPathComponent(
                photoID,
                isDirectory: true
            )
    }
}
