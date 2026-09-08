import Combine
import Foundation

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

    func makeAuthClient() -> AuthClient {
        AuthClient(baseURL: Self.productionBaseURL)
    }

    func makeClient() throws -> APIClient {
        guard let credential, !credential.isExpired() else {
            throw APIClientError.notConfigured
        }

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
                    self?.handleUnauthorized()
                }
            }
        )
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
        revision += 1
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
