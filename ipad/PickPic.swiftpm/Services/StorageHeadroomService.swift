import Foundation

/*
 * Storage headroom estimate.
 *
 * Before conversion starts -- the most expensive step in the pipeline --
 * this gives the photographer a heads-up if the batch looks likely to
 * exceed the account's remaining storage headroom, so the pipeline can
 * pause at .prepared for a "Continue Anyway" decision instead of paying
 * for a conversion whose upload is likely to be rejected. It is still
 * only ever a recommendation: the server's storage-cap 403
 * (wouldExceedStorageCap in worker/index.ts) is the sole authoritative
 * gate, and the photographer can always continue anyway.
 *
 * The estimate can't be exact. photos.byte_size on the server is the
 * converted proof's size, not the source RAW's, and the client has no way
 * to know a photo's true output size before converting it. Docs/pricing.md
 * documents proofs landing near 4 MB regardless of source RAW size, since
 * conversion always downsamples to the same bounded long edge and quality
 * (ImageConversionService.maxLongEdge / .jpegQuality) -- so a flat
 * per-photo figure, rounded up for margin, is a better anchor than trying
 * to derive a RAW-to-proof ratio.
 */
enum StorageHeadroomService {
    private static let estimatedProofBytes: Int64 =
        5 * 1_024 * 1_024

    static func warningMessage(
        for job: UploadJob,
        client: APIClient
    ) async -> String? {
        let photosToConvert = job.photosToConvertCount

        guard photosToConvert > 0 else {
            return nil
        }

        guard
            let usage = try? await client
                .fetchStorageUsage()
        else {
            return nil
        }

        let estimatedBytes =
        Int64(photosToConvert)
            * estimatedProofBytes

        let remainingBytes = max(
            usage.capBytes - usage.totalBytes,
            0
        )

        guard estimatedBytes > remainingBytes else {
            return nil
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let estimatedText = formatter.string(
            fromByteCount: estimatedBytes
        )
        let remainingText = formatter.string(
            fromByteCount: remainingBytes
        )

        return """
        This batch could use about \(estimatedText), more than the \
        \(remainingText) left before this account's storage limit. \
        Uploads may be rejected once the limit is reached.
        """
    }
}
