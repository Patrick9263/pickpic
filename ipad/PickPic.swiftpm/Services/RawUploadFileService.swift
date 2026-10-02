import CryptoKit
import Foundation

/*
 * How one RAW is cut into the parts of a resumable multipart upload
 * (#362/#368). Pure, so the arithmetic every other piece leans on -- the
 * split on disk, the missing-part list, the progress bar -- is tested once
 * here rather than trusted in three places.
 *
 * Parts are 1-based, matching R2 and PUT .../raw/parts/:n. Every part is
 * partSize bytes except the last, which carries the remainder; the worker
 * rejects a part of any other length, so this has to agree with
 * rawUploadPartCount and the expectedSize check in worker/index.ts exactly.
 */
struct RawUploadPartPlan: Equatable, Sendable {
    /*
     * Must stay equal to RAW_UPLOAD_PART_SIZE in worker/index.ts. Staging
     * splits at this size before /raw/start has answered -- the hash that
     * start needs is computed during that same pass -- and the sync re-splits
     * if the server ever reports a different size, so a mismatch costs one
     * extra read of the file rather than a failed upload.
     */
    static let defaultPartSize: Int64 = 8 * 1_024 * 1_024

    let byteSize: Int64
    let partSize: Int64

    init(byteSize: Int64, partSize: Int64) {
        precondition(partSize > 0, "A part size must be positive.")

        self.byteSize = max(byteSize, 0)
        self.partSize = partSize
    }

    var partCount: Int {
        Int((byteSize + partSize - 1) / partSize)
    }

    var partNumbers: ClosedRange<Int>? {
        partCount > 0 ? 1...partCount : nil
    }

    /* The half-open byte range a part covers in the original file. */
    func byteRange(ofPart partNumber: Int) -> Range<Int64>? {
        guard partCount > 0, (1...partCount).contains(partNumber) else {
            return nil
        }

        let start = Int64(partNumber - 1) * partSize

        return start..<min(start + partSize, byteSize)
    }

    func size(ofPart partNumber: Int) -> Int64? {
        byteRange(ofPart: partNumber).map { range in
            range.upperBound - range.lowerBound
        }
    }

    /*
     * The parts to send, given the ones /raw/start reports already landed.
     * Numbers outside the plan are ignored rather than trusted.
     *
     * When nothing is missing the last part is sent again anyway. The server
     * completes an upload from inside the request that lands its final part,
     * and releases its completion claim if R2's complete() fails, expecting
     * a retried part to finish the job -- so "every part landed" with the
     * photo still asking for its RAW means exactly that retry is owed. The
     * worker treats a re-sent part as an idempotent overwrite.
     */
    func partsToSend(landedParts: [Int]) -> [Int] {
        guard let partNumbers else {
            return []
        }

        let landed = Set(landedParts)
        let missing = partNumbers.filter { partNumber in
            !landed.contains(partNumber)
        }

        return missing.isEmpty ? [partCount] : missing
    }
}

/*
 * Per-file progress for a multipart RAW upload (#268): the bytes of every
 * part already landed, plus whatever the part(s) currently in flight have
 * sent so far, over the file's whole size. Shaped to feed
 * RawDeliveryProgress.Phase.uploading unchanged, so LikedPhotosView's bar
 * reads the same whether a file travels as one request or ten.
 */
struct RawUploadProgressTally: Equatable, Sendable {
    let plan: RawUploadPartPlan

    private(set) var landedParts: Set<Int>

    private(set) var inFlightSentBytes: [Int: Int64] = [:]

    init(plan: RawUploadPartPlan, landedParts: some Sequence<Int>) {
        self.plan = plan
        self.landedParts = Set(
            landedParts.filter { partNumber in
                plan.size(ofPart: partNumber) != nil
            }
        )
    }

    /*
     * Clamped to the part's own size: URLSession can report a sent count a
     * little over the body length right at completion, and a part must never
     * be able to push the total past the file.
     */
    mutating func recordSent(_ sentBytes: Int64, forPart partNumber: Int) {
        guard
            let partSize = plan.size(ofPart: partNumber),
            !landedParts.contains(partNumber)
        else {
            return
        }

        inFlightSentBytes[partNumber] = min(max(sentBytes, 0), partSize)
    }

    mutating func markLanded(_ partNumber: Int) {
        guard plan.size(ofPart: partNumber) != nil else {
            return
        }

        inFlightSentBytes.removeValue(forKey: partNumber)
        landedParts.insert(partNumber)
    }

    /* A retried part is re-sent from its first byte, so its count restarts. */
    mutating func markFailed(_ partNumber: Int) {
        inFlightSentBytes.removeValue(forKey: partNumber)
    }

    var sentBytes: Int64 {
        let landedBytes = landedParts.reduce(Int64(0)) { total, partNumber in
            total + (plan.size(ofPart: partNumber) ?? 0)
        }

        let inFlightBytes = inFlightSentBytes.values.reduce(0, +)

        return min(landedBytes + inFlightBytes, plan.byteSize)
    }

    var totalBytes: Int64 {
        plan.byteSize
    }
}

/*
 * A RAW staged as part files, ready for /raw/start and the part PUTs.
 * sha256 and byteSize describe the whole file -- they are what start is
 * keyed on -- and partURLs[n - 1] holds part n.
 */
struct StagedRawUpload: Sendable {
    let photoID: String
    let filename: String
    let sha256: String
    let byteSize: Int64
    let partSize: Int64
    let partURLs: [URL]

    var plan: RawUploadPartPlan {
        RawUploadPartPlan(byteSize: byteSize, partSize: partSize)
    }

    func partURL(_ partNumber: Int) -> URL? {
        partURLs.indices.contains(partNumber - 1)
            ? partURLs[partNumber - 1]
            : nil
    }
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
     * (#215) -- checking it here as well as there is not redundant: it
     * refuses the file before staging writes up to 100 MB of part files
     * into the app's container only for /raw/start to turn it away.
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
        reference: EventFolderReference,
        partSize: Int64 = RawUploadPartPlan.defaultPartSize
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

        /*
         * Hashed from the same bytes that are written into the parts, in one
         * pass, so the value describes exactly what is going to be uploaded
         * -- and a 100 MB RAW is read once rather than copied and then read
         * again to hash it.
         */
        let split = try splitAndHash(
            sourceURL: located.url,
            into: stagingDirectory,
            partSize: partSize
        )

        /* The file can have grown since its size was read above. */
        try validate(
            filename: filename,
            byteSize: split.byteSize
        )

        return StagedRawUpload(
            photoID: photoID,
            filename: filename,
            sha256: split.sha256,
            byteSize: split.byteSize,
            partSize: partSize,
            partURLs: split.partURLs
        )
    }

    /*
     * Writes the source as consecutive part files of partSize bytes (the
     * last one shorter), feeding every byte through SHA-256 on the way.
     * Reads in chunks well under a part so memory stays flat however large
     * the RAW is.
     */
    private static func splitAndHash(
        sourceURL: URL,
        into directoryURL: URL,
        partSize: Int64
    ) throws -> (partURLs: [URL], sha256: String, byteSize: Int64) {
        let readChunkSize: Int64 = 1_024 * 1_024

        let reader = try FileHandle(forReadingFrom: sourceURL)

        defer {
            try? reader.close()
        }

        var hasher = SHA256()
        var partURLs: [URL] = []
        var totalBytes: Int64 = 0
        var reachedEnd = false

        while !reachedEnd {
            var writer: FileHandle?
            var partBytes: Int64 = 0

            defer {
                try? writer?.close()
            }

            while partBytes < partSize {
                let data =
                try reader.read(
                    upToCount: Int(
                        min(readChunkSize, partSize - partBytes)
                    )
                )
                ?? Data()

                guard !data.isEmpty else {
                    reachedEnd = true
                    break
                }

                if writer == nil {
                    let partURL =
                    directoryURL.appendingPathComponent(
                        "part-\(partURLs.count + 1)",
                        isDirectory: false
                    )

                    FileManager.default.createFile(
                        atPath: partURL.path,
                        contents: nil
                    )

                    writer = try FileHandle(forWritingTo: partURL)
                    partURLs.append(partURL)
                }

                hasher.update(data: data)
                try writer?.write(contentsOf: data)
                partBytes += Int64(data.count)
            }

            totalBytes += partBytes
        }

        let sha256 = hasher.finalize()
            .map { byte in
                String(format: "%02x", byte)
            }
            .joined()

        return (partURLs, sha256, totalBytes)
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
