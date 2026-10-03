import Combine
import CryptoKit
import Foundation

/*
 * Which account a piece of on-device work belongs to, and where per-account
 * state is kept. Pure so PickPicTests can pin the rules: getting ownership
 * wrong either uploads one account's photos into another's events, or strands
 * work that should have resumed.
 */
enum AccountScope {
    /*
     * Work with no account recorded predates jobs carrying one, from a build
     * that could not switch accounts, so it belongs to whoever is signed in --
     * and UploadQueueStore.adoptUnownedJobs stamps it with that account the
     * first time one is known, after which this rule no longer applies to it.
     *
     * Work tagged with an account is usable only under that same account. A
     * credential whose own account is not known yet (see
     * SessionCredential.accountID) owns nothing tagged: guessing would be
     * exactly the cross-account upload this exists to prevent, and the next
     * refreshSession() settles it.
     */
    static func owns(
        currentAccountID: String?,
        workAccountID: String?
    ) -> Bool {
        guard let workAccountID else {
            return true
        }

        return workAccountID == currentAccountID
    }

    /*
     * The single, unscoped file every build before #376 wrote. It is still
     * read while the signed-in account is unknown, so an upgrade launched
     * offline shows the same list it always did, and it is handed to the
     * first account that becomes known (EventListViewModel.adoptLegacyCache).
     */
    static let legacyEventCacheFilename = "events-cache.json"

    static func eventCacheFilename(
        for accountID: String?
    ) -> String {
        guard let accountID else {
            return legacyEventCacheFilename
        }

        return "events-cache-\(filenameComponent(for: accountID)).json"
    }

    /*
     * Account ids are server-generated UUIDs today, which pass through
     * untouched so the files stay recognisable. Anything else is hashed
     * rather than filtered: filtering could map two ids to one file, which
     * would put two accounts' events back in the same cache.
     */
    static func filenameComponent(
        for accountID: String
    ) -> String {
        let isSafe =
            !accountID.isEmpty
            && accountID.count <= 64
            && accountID.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "-"
                        || scalar == "_")
            }

        if isSafe {
            return accountID
        }

        return SHA256.hash(data: Data(accountID.utf8))
            .map { byte in
                String(format: "%02x", byte)
            }
            .joined()
    }
}

enum APIConfigurationError: LocalizedError {
    case missingEmail

    var errorDescription: String? {
        switch self {
        case .missingEmail:
            return "Enter the email address for your PickPic account."
        }
    }
}

/*
 * Holds this iPad's PickPic sign-in and hands out clients that spend it.
 *
 * Until #188 this stored a Cloudflare Access service token -- one shared
 * machine credential, provisioned by hand in the Cloudflare dashboard, that
 * every iPad would have had to share and that always resolved to the bootstrap
 * account. It now stores a per-account session against app.pickpic.photos,
 * which is the same worker code with AUTH_MODE=session and no Access in front
 * of it. The practical difference is that a session belongs to an account and
 * expires, and both of those have to be visible to the upload pipeline.
 */
@MainActor
final class APIConfigurationStore: ObservableObject {
    private enum Account {
        static let session = "pickpic-session"

        /*
         * The service-token pair this app used before #188. Nothing reads
         * these any more; they are cleared on first launch of the new build
         * because a Cloudflare Access service token sitting unused in a
         * Keychain is a live credential nobody is watching.
         */
        static let legacyClientID = "cloudflare-client-id"
        static let legacyClientSecret = "cloudflare-client-secret"
    }

    /*
     * app.pickpic.photos rather than admin.pickpic.photos. Both run identical
     * code against the same database, but only this one is configured for
     * session auth -- admin.pickpic.photos sits behind Cloudflare Access,
     * which would refuse these requests at the edge before the worker ever
     * saw the session cookie.
     */
    static let productionBaseURL = URL(
        string: "https://app.pickpic.photos"
    )!

    @Published private(set) var credential: SessionCredential?
    @Published private(set) var revision = 0

    /*
     * Set when a request came back 401 so the UI can say why the iPad
     * suddenly needs signing in again, rather than presenting a bare sign-in
     * sheet in the middle of a shoot with no explanation.
     */
    @Published private(set) var signInRequiredMessage: String?

    /*
     * Fired, synchronously, whenever this store holds a credential whose
     * account is known -- on being set, and on every save after. App.swift
     * uses it to hand state recorded before #376 (untagged upload jobs, the
     * unscoped event cache) to that account. "The first account this iPad
     * identifies" is the right owner because builds before #375 could not
     * switch accounts, and replaceCredential(with:) identifies an outgoing
     * account before switching away from it, so the incoming one cannot
     * claim the outgoing one's work. Both handlers are idempotent, so
     * firing on every save costs a check and nothing more.
     */
    var onAccountIdentified: ((String) -> Void)? {
        didSet {
            notifyAccountIdentified()
        }
    }

    init() {
        credential = Self.loadCredential()

        Self.clearLegacyAccessCredentials()
    }

    /*
     * An expired credential is treated as no credential at all: every request
     * it could make would 401, and letting the pipeline start a batch it
     * cannot finish is worse than refusing to start.
     */
    var isConfigured: Bool {
        guard let credential else {
            return false
        }

        return !credential.isExpired()
    }

    var isExpiringSoon: Bool {
        credential?.isExpiringSoon() == true
    }

    var accountDescription: String? {
        guard let credential else {
            return nil
        }

        return credential.accountName ?? credential.email
    }

    /*
     * Read regardless of expiry, unlike isConfigured: an expired session
     * still says whose work is on screen and in the queue, and a sign-in
     * to the same account should find that work exactly where it was.
     */
    var accountID: String? {
        credential?.accountID
    }

    func owns(_ job: UploadJob) -> Bool {
        AccountScope.owns(
            currentAccountID: accountID,
            workAccountID: job.accountID
        )
    }

    func makeAuthClient() -> AuthClient {
        AuthClient(baseURL: Self.productionBaseURL)
    }

    func makeClient() throws -> APIClient {
        guard let credential, !credential.isExpired() else {
            throw APIClientError.notConfigured
        }

        let token = credential.token

        return APIClient(
            baseURL: Self.productionBaseURL,
            credential: credential,
            onUnauthorized: { [weak self] in
                /*
                 * Hopped rather than called directly because APIClient runs
                 * its requests off the main actor, and this store is
                 * @MainActor state that SwiftUI is observing.
                 */
                Task { @MainActor in
                    self?.handleUnauthorized(token: token)
                }
            }
        )
    }

    /*
     * Mirrors what the web app's useSession hook gets for free from the
     * browser's own cookie handling: a GET /api/auth/session that re-aligns
     * the stored expiry with however far the row has slid. This app turns
     * off automatic cookie handling everywhere (see AuthClient), so nothing
     * refreshes the Keychain value unless something calls this -- App.swift
     * does, at launch and on every foreground. Best effort: a failure here
     * (offline, a dead session) just leaves the existing credential in
     * place, and a genuinely dead session still surfaces the normal way, as
     * a 401 from the next admin request.
     */
    func refreshSession() async {
        guard let credential, !credential.isExpired() else {
            return
        }

        guard
            let refreshed = try? await makeAuthClient()
                .describe(credential)
        else {
            return
        }

        /*
         * The await above is long enough for a sign-out or an account switch
         * to land, and saving then would resurrect the session it replaced.
         */
        guard self.credential?.token == credential.token else {
            return
        }

        /*
         * Usually nothing has changed -- the slide moves at most once a day
         * -- and saving anyway would bump revision for nothing, restarting
         * every task keyed on it (#384).
         */
        guard !credential.isEquivalent(to: refreshed) else {
            return
        }

        try? save(refreshed)
    }

    /*
     * Installs a freshly redeemed sign-in, then revokes the session it
     * replaced, as signOut() would have. Shared by every way a link is
     * redeemed -- a tapped universal link and the Account sheet's paste
     * field -- so that switching accounts from either leaves no live session
     * behind. Revoking is best effort: the local switch has already happened,
     * and a session nothing holds any more is only a dead row server-side.
     *
     * Revoking is also why the previous account's in-flight requests start
     * answering 401 a moment later; handleUnauthorized(token:) and
     * UploadQueueStore's background-completion path both check whose request
     * it was, so those do not sign this new session out.
     */
    func replaceCredential(
        with newCredential: SessionCredential
    ) async throws {
        /*
         * A credential saved before accounts were recorded may still not
         * know its own account, and the moment it is replaced is the last
         * chance to ask -- after this its work could only be claimed by the
         * account replacing it (see onAccountIdentified). Best effort, and
         * normally a no-op: refreshSession() has usually filled it in at
         * launch.
         */
        if credential?.accountID == nil {
            await refreshSession()
        }

        let previousCredential = credential

        try save(newCredential)

        if let previousCredential,
           previousCredential.token != newCredential.token {
            try? await makeAuthClient().signOut(previousCredential)
        }
    }

    func save(_ credential: SessionCredential) throws {
        try KeychainStore.set(
            String(
                decoding: try Self.encoder.encode(credential),
                as: UTF8.self
            ),
            for: Account.session
        )

        self.credential = credential
        signInRequiredMessage = nil

        notifyAccountIdentified()

        revision += 1
    }

    private func notifyAccountIdentified() {
        if let accountID {
            onAccountIdentified?(accountID)
        }
    }

    /*
     * Revokes the session server-side before forgetting it locally. The local
     * clear happens either way -- a token this device can no longer use is
     * worth nothing to keep, and a network failure during sign-out must not
     * leave the operator stuck signed in.
     */
    func signOut() async {
        if let credential {
            try? await makeAuthClient().signOut(credential)
        }

        clearCredential(message: nil)
    }

    /*
     * The single place a 401 lands, whichever request produced it. Clearing
     * rather than keeping the token is deliberate: this worker returns 401
     * only for a missing, expired or revoked session, so there is nothing a
     * retry with the same value could fix, and holding it would let the
     * upload pipeline keep firing requests that cannot succeed.
     */
    func handleUnauthorized() {
        guard credential != nil else {
            return
        }

        clearCredential(
            message: APIClientError.signInRequiredMessage
        )
    }

    /*
     * A 401 says the session that sent the request is dead, which is only
     * this store's credential if the request carried it. Since accounts can
     * be switched, a request still in flight from the previous session --
     * revoked by the switch itself -- routinely comes back 401 after the new
     * one is installed, and clearing on it would sign the new account out
     * seconds after it signed in.
     */
    func handleUnauthorized(token: String) {
        guard credential?.token == token else {
            return
        }

        handleUnauthorized()
    }

    func dismissSignInRequiredMessage() {
        signInRequiredMessage = nil
    }

    private func clearCredential(message: String?) {
        try? KeychainStore.clear(account: Account.session)

        credential = nil
        signInRequiredMessage = message
        revision += 1
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func loadCredential() -> SessionCredential? {
        guard
            let stored = try? KeychainStore.string(
                for: Account.session
            ),
            let data = stored.data(using: .utf8)
        else {
            return nil
        }

        return try? decoder.decode(
            SessionCredential.self,
            from: data
        )
    }

    private static func clearLegacyAccessCredentials() {
        try? KeychainStore.clear(account: Account.legacyClientID)
        try? KeychainStore.clear(account: Account.legacyClientSecret)
    }
}
