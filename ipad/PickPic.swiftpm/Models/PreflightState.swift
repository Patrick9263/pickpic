import Foundation

/*
 * A photo the event already knows about, keyed by the RAW filename the
 * iPad originally uploaded.
 *
 * Both hashes can be nil for photos uploaded before the source-hash
 * migration landed, which is why a match alone never justifies skipping.
 */
struct PreflightMatch:
    Codable,
    Hashable,
    Sendable
{
    let filename: String
    let photoID: String
    let sourceSha256: String?
    let finalSha256: String?

    private enum CodingKeys:
        String,
        CodingKey
    {
        case filename
        case photoID = "photoId"
        case sourceSha256
        case finalSha256
    }

    var hasComparableHash: Bool {
        sourceSha256 != nil
            || finalSha256 != nil
    }

    /*
     * Mirrors findDuplicatePhoto in worker/index.ts, which treats a photo
     * as a duplicate when the incoming source hash equals either the
     * stored original hash or the stored final hash.
     *
     * This is the only place the client makes that judgement. Keep it in
     * sync with the worker if the server-side rule ever changes.
     */
    func matches(
        localSha256: String
    ) -> Bool {
        let normalized = localSha256.lowercased()

        return normalized == sourceSha256?.lowercased()
            || normalized == finalSha256?.lowercased()
    }
}

/*
 * Durable result of the duplicate preflight pass for a single upload job.
 *
 * Preflight is an optimisation only: it lets PickPic skip converting RAWs
 * the event already has, instead of paying a full RAW decode and then
 * having the server reject the upload as a duplicate. The server-side
 * check remains authoritative, so any gap or bug here degrades to the
 * previous behaviour rather than losing photos.
 */
struct PreflightState:
    Codable,
    Hashable,
    Sendable
{
    var startedAt: Date?
    var checkedAt: Date?

    /*
     * Source photo IDs that have been through the local hash comparison.
     * Persisted so an interrupted preflight resumes instead of rehashing.
     */
    var checkedSourcePhotoIDs: Set<String>

    /* Confirmed by hash against a photo the event already has. */
    var duplicateSourcePhotoIDs: Set<String>

    /*
     * Filename matched an existing photo, but the server had no hash to
     * compare against. Treated as convertible, surfaced for visibility.
     */
    var unconfirmedSourcePhotoIDs: Set<String>

    /*
     * Hashes computed during preflight, reused by conversion so large RAW
     * files are not read twice.
     */
    var hashesBySourcePhotoID: [String: String]

    /* Existing server-side photo ID, for display and later linking. */
    var existingPhotoIDsBySourcePhotoID: [String: String]

    /* Source photo IDs the photographer chose to convert anyway. */
    var overriddenSourcePhotoIDs: Set<String>

    var errorMessage: String?

    static let empty = PreflightState(
        startedAt: nil,
        checkedAt: nil,
        checkedSourcePhotoIDs: [],
        duplicateSourcePhotoIDs: [],
        unconfirmedSourcePhotoIDs: [],
        hashesBySourcePhotoID: [:],
        existingPhotoIDsBySourcePhotoID: [:],
        overriddenSourcePhotoIDs: [],
        errorMessage: nil
    )

    var duplicateCount: Int {
        duplicateSourcePhotoIDs.count
    }

    var unconfirmedCount: Int {
        unconfirmedSourcePhotoIDs.count
    }

    /*
     * Duplicates the photographer has not chosen to override. These are
     * the photos conversion will skip.
     */
    var skippedSourcePhotoIDs: Set<String> {
        duplicateSourcePhotoIDs
            .subtracting(overriddenSourcePhotoIDs)
    }

    var skippedCount: Int {
        skippedSourcePhotoIDs.count
    }

    var hasSkippableDuplicates: Bool {
        !skippedSourcePhotoIDs.isEmpty
    }

    var didComplete: Bool {
        checkedAt != nil
    }

    func shouldSkipConversion(
        forSourcePhotoID sourcePhotoID: String
    ) -> Bool {
        duplicateSourcePhotoIDs
            .contains(sourcePhotoID)
            && !overriddenSourcePhotoIDs
                .contains(sourcePhotoID)
    }

    func precomputedSha256(
        forSourcePhotoID sourcePhotoID: String
    ) -> String? {
        hashesBySourcePhotoID[sourcePhotoID]
    }

    mutating func overrideAllDuplicates() {
        overriddenSourcePhotoIDs
            .formUnion(duplicateSourcePhotoIDs)
    }

    mutating func clearOverrides() {
        overriddenSourcePhotoIDs.removeAll()
    }

    /*
     * Older persisted jobs predate every field here, so each one decodes
     * with a fallback. This keeps existing upload-queue.json readable.
     */
    init(
        startedAt: Date? = nil,
        checkedAt: Date? = nil,
        checkedSourcePhotoIDs: Set<String> = [],
        duplicateSourcePhotoIDs: Set<String> = [],
        unconfirmedSourcePhotoIDs: Set<String> = [],
        hashesBySourcePhotoID: [String: String] = [:],
        existingPhotoIDsBySourcePhotoID: [String: String] = [:],
        overriddenSourcePhotoIDs: Set<String> = [],
        errorMessage: String? = nil
    ) {
        self.startedAt = startedAt
        self.checkedAt = checkedAt
        self.checkedSourcePhotoIDs =
            checkedSourcePhotoIDs
        self.duplicateSourcePhotoIDs =
            duplicateSourcePhotoIDs
        self.unconfirmedSourcePhotoIDs =
            unconfirmedSourcePhotoIDs
        self.hashesBySourcePhotoID =
            hashesBySourcePhotoID
        self.existingPhotoIDsBySourcePhotoID =
            existingPhotoIDsBySourcePhotoID
        self.overriddenSourcePhotoIDs =
            overriddenSourcePhotoIDs
        self.errorMessage = errorMessage
    }

    private enum CodingKeys:
        String,
        CodingKey
    {
        case startedAt
        case checkedAt
        case checkedSourcePhotoIDs
        case duplicateSourcePhotoIDs
        case unconfirmedSourcePhotoIDs
        case hashesBySourcePhotoID
        case existingPhotoIDsBySourcePhotoID
        case overriddenSourcePhotoIDs
        case errorMessage
    }

    init(
        from decoder: Decoder
    ) throws {
        let container =
        try decoder.container(
            keyedBy: CodingKeys.self
        )

        startedAt =
        try container.decodeIfPresent(
            Date.self,
            forKey: .startedAt
        )

        checkedAt =
        try container.decodeIfPresent(
            Date.self,
            forKey: .checkedAt
        )

        checkedSourcePhotoIDs =
        try container.decodeIfPresent(
            Set<String>.self,
            forKey: .checkedSourcePhotoIDs
        )
        ?? []

        duplicateSourcePhotoIDs =
        try container.decodeIfPresent(
            Set<String>.self,
            forKey: .duplicateSourcePhotoIDs
        )
        ?? []

        unconfirmedSourcePhotoIDs =
        try container.decodeIfPresent(
            Set<String>.self,
            forKey: .unconfirmedSourcePhotoIDs
        )
        ?? []

        hashesBySourcePhotoID =
        try container.decodeIfPresent(
            [String: String].self,
            forKey: .hashesBySourcePhotoID
        )
        ?? [:]

        existingPhotoIDsBySourcePhotoID =
        try container.decodeIfPresent(
            [String: String].self,
            forKey:
                    .existingPhotoIDsBySourcePhotoID
        )
        ?? [:]

        overriddenSourcePhotoIDs =
        try container.decodeIfPresent(
            Set<String>.self,
            forKey: .overriddenSourcePhotoIDs
        )
        ?? []

        errorMessage =
        try container.decodeIfPresent(
            String.self,
            forKey: .errorMessage
        )
    }
}
