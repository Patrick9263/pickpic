import Foundation

/*
 * One PickPic sign-in, as this device holds it.
 *
 * The token is the value of the worker's __Host-pickpic_session cookie. The
 * app stores and sends it by hand rather than letting URLSession's cookie
 * storage do it, for two reasons that both matter here:
 *
 *   * background uploads are dispatched out of process by nsurlsessiond, and
 *     what it does with a shared cookie jar across app relaunches is not
 *     something the upload pipeline should depend on. A header set on the
 *     request travels with the task.
 *
 *   * the credential has to survive in the Keychain with the same
 *     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly guarantee the service
 *     token had, so an upload can resume while the iPad is locked.
 *
 * expiresAt is not decoration, and it is not fixed at sign-in either.
 * worker/session.ts slides it forward on use -- 30 days of idle time, capped
 * at a year from creation -- so a stolen cookie still dies on a hard date, but
 * an actively-used one should not. The app never sees a browser's automatic
 * Set-Cookie handling (see below), so nothing refreshes this value unless
 * APIConfigurationStore.refreshSession() spends a round trip to ask for it;
 * skip that and this reads exactly like the old fixed-lifetime session,
 * expiring on the date parsed at sign-in however far the server-side row has
 * actually slid. Knowing the date lets the queue warn before a long shoot
 * rather than discovering it as a 401 halfway through.
 */
struct SessionCredential: Codable, Hashable, Sendable {
    let token: String
    let expiresAt: Date

    /** Shown so the operator can see which account the iPad is uploading to. */
    let accountName: String?
    let email: String?

    init(
        token: String,
        expiresAt: Date,
        accountName: String? = nil,
        email: String? = nil
    ) {
        self.token = token
        self.expiresAt = expiresAt
        self.accountName = accountName
        self.email = email
    }

    func isExpired(asOf now: Date = Date()) -> Bool {
        expiresAt <= now
    }

    /*
     * A shoot converted and uploaded over a weekend can easily outlive a few
     * days of remaining session, and BackgroundUploadSession's resource
     * timeout is a full seven days on its own -- a transfer started inside
     * this window can still be in flight when the session dies. Warning at the
     * same horizon means the operator is told to sign in again while the queue
     * is idle instead of mid-batch.
     */
    static let renewalWarningInterval: TimeInterval = 7 * 24 * 60 * 60

    func isExpiringSoon(asOf now: Date = Date()) -> Bool {
        !isExpired(asOf: now)
            && expiresAt.timeIntervalSince(now) <= Self.renewalWarningInterval
    }

    func withAccountDetails(
        accountName: String?,
        email: String?
    ) -> SessionCredential {
        SessionCredential(
            token: token,
            expiresAt: expiresAt,
            accountName: accountName,
            email: email
        )
    }

    func withRefreshedExpiry(_ expiresAt: Date) -> SessionCredential {
        SessionCredential(
            token: token,
            expiresAt: expiresAt,
            accountName: accountName,
            email: email
        )
    }
}

extension SessionCredential {
    /** Matches worker/session.ts's SESSION_COOKIE_NAME. */
    static let cookieName = "__Host-pickpic_session"

    static func token(fromPastedText text: String) -> String? {
        AuthLink(pastedText: text)?.token
    }

    /*
     * Reads the session out of the worker's Set-Cookie header.
     *
     * The app parses this rather than reading HTTPCookieStorage because it
     * never lets URLSession handle cookies at all (see the type comment), so
     * nothing would be in that store to read. Max-Age is the authority on the
     * expiry, whether this is the cookie minted at sign-in or the one
     * GET /api/auth/session re-issues on every call once the row has slid --
     * both are the same header shape, so the same parse serves either.
     *
     * A cleared cookie -- Max-Age=0 with an empty value, which is how sign-out
     * is expressed -- is not a credential and returns nil.
     */
    static func credential(
        fromSetCookieHeader header: String,
        receivedAt: Date = Date()
    ) -> SessionCredential? {
        var token: String?
        var maxAge: TimeInterval?

        for (index, rawAttribute) in header
            .split(separator: ";")
            .enumerated() {
            let attribute = rawAttribute.trimmingCharacters(
                in: .whitespaces
            )

            guard let separator = attribute.firstIndex(of: "=") else {
                continue
            }

            let name = String(attribute[attribute.startIndex..<separator])

            let value = String(
                attribute[attribute.index(after: separator)...]
            )

            /*
             * The cookie's own name=value pair is always first; an attribute
             * later in the header that happened to be called the same thing
             * must not overwrite it.
             */
            if index == 0 {
                guard name == cookieName, !value.isEmpty else {
                    return nil
                }

                token = value

                continue
            }

            if name.caseInsensitiveCompare("Max-Age") == .orderedSame {
                maxAge = TimeInterval(value)
            }
        }

        guard let token, let maxAge, maxAge > 0 else {
            return nil
        }

        return SessionCredential(
            token: token,
            expiresAt: receivedAt.addingTimeInterval(maxAge)
        )
    }
}

/*
 * Which consume endpoint a token belongs to. The token itself carries no
 * marker -- both kinds are the same 32 random bytes from generateAuthToken --
 * so the only signal is the path of the link it arrived in.
 */
enum AuthLinkKind: Equatable, Sendable {
    /** /sign-in, redeemed at /api/auth/magic-link/consume. */
    case signIn

    /** /sign-up, redeemed at /api/auth/signup/consume. */
    case signUp

    /*
     * A bare token, or a link whose path is neither. AuthClient.redeem(_:)
     * tries sign-in first and then signup, which is safe because a consume
     * handed the other kind's token finds no row and writes nothing.
     */
    case unknown
}

struct AuthLink: Equatable, Sendable {
    let token: String
    let kind: AuthLinkKind

    init(token: String, kind: AuthLinkKind) {
        self.token = token
        self.kind = kind
    }

    /*
     * Pulls the token, and the kind of link it came in, out of whatever the
     * operator managed to paste -- or out of a universal link's absoluteString,
     * which goes through the same parse so the two paths cannot disagree.
     *
     * A link in Safari rather than this app is copied out of Mail and pasted.
     * In practice that clipboard can hold the bare URL, the URL wrapped in
     * punctuation, several lines of quoted email body around it, or -- if they
     * copied from a page rather than a link -- just the token. All four have to
     * work, because the alternative is an operator who cannot sign in staring
     * at a field that says "invalid".
     *
     * The last occurrence wins: a quoted reply chain repeats the older link
     * above the newest one, and only the newest is unconsumed. The kind is read
     * from that same occurrence, so a reply quoting a sign-in link above a
     * newer sign-up link routes to signup.
     */
    init?(pastedText text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        if let queryRange = trimmed.range(
            of: "token=",
            options: .backwards
        ) {
            guard
                let token = Self.normalizedToken(
                    String(trimmed[queryRange.upperBound...])
                )
            else {
                return nil
            }

            self.init(
                token: token,
                kind: Self.kind(
                    ofLinkBefore: trimmed[..<queryRange.lowerBound]
                )
            )

            return
        }

        /*
         * No query string at all, so this is either a bare token or something
         * that was never a sign-in link. Anything containing a scheme or
         * whitespace is the latter -- returning it would send junk to the
         * consume endpoint and report "expired or already used", which is a
         * misleading thing to tell someone who pasted the wrong thing.
         */
        guard
            !trimmed.contains("://"),
            trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            return nil
        }

        guard let token = Self.normalizedToken(trimmed) else {
            return nil
        }

        self.init(token: token, kind: .unknown)
    }

    /*
     * Reads the path immediately before the query that holds "token=". Only
     * the end of the path is compared, so the scheme, host and any punctuation
     * a mail client wrapped around the URL do not matter. The query between
     * "?" and "token=" has to be free of whitespace, or the "?" belongs to some
     * other line of the pasted text and says nothing about this token.
     */
    private static func kind(
        ofLinkBefore prefix: Substring
    ) -> AuthLinkKind {
        guard let questionMark = prefix.lastIndex(of: "?") else {
            return .unknown
        }

        let leadingQuery = prefix[prefix.index(after: questionMark)...]

        guard
            leadingQuery.rangeOfCharacter(
                from: .whitespacesAndNewlines
            ) == nil
        else {
            return .unknown
        }

        var path = prefix[..<questionMark]

        if path.hasSuffix("/") {
            path = path.dropLast()
        }

        if path.hasSuffix("/sign-up") {
            return .signUp
        }

        if path.hasSuffix("/sign-in") {
            return .signIn
        }

        return .unknown
    }

    /*
     * The base64url alphabet generateAuthToken emits. Used to find where a
     * token ends inside pasted text, so a trailing "&foo=bar", a quotation
     * mark a mail client wrapped the link in, or a newline does not become
     * part of the token.
     */
    private static let tokenCharacters = CharacterSet(
        charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    private static func normalizedToken(
        _ candidate: String
    ) -> String? {
        let token = String(
            candidate.prefix { character in
                character.unicodeScalars.allSatisfy(
                    tokenCharacters.contains
                )
            }
        )

        return token.isEmpty ? nil : token
    }
}

extension URL {
    /*
     * The value an Origin header has to carry to satisfy the worker's
     * isSameOriginRequest, which compares it against
     * new URL(request.url).origin -- scheme, host and non-default port, and
     * nothing else. Built rather than taken from absoluteString because a base
     * URL written with a trailing slash would otherwise send
     * "https://app.pickpic.photos/" and be refused on every mutation.
     */
    var originHeaderValue: String {
        guard
            let scheme = scheme,
            let host = host()
        else {
            return absoluteString
        }

        guard let port else {
            return "\(scheme)://\(host)"
        }

        return "\(scheme)://\(host):\(port)"
    }
}

enum AuthClientError: LocalizedError {
    case invalidResponse
    case missingSessionCookie
    case invalidSignInLink
    case accountCreatedButNotSignedIn
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "PickPic returned an invalid network response."

        case .missingSessionCookie:
            return """
            PickPic accepted the sign-in link but did not return a session. \
            Try requesting a new link.
            """

        case .invalidSignInLink:
            return """
            That does not look like a PickPic link. Copy the link from the \
            email and paste it again.
            """

        case .accountCreatedButNotSignedIn:
            return """
            Your PickPic account was created, but signing this iPad in \
            failed. Request a sign-in link with the same email address to \
            finish.
            """

        case let .server(statusCode, message):
            return "\(message) (HTTP \(statusCode))"
        }
    }
}

/*
 * The /api/auth half of the worker, which mints the credential APIClient
 * spends. Kept separate from APIClient because it is the one client that runs
 * without a session -- APIClient cannot be constructed until this has
 * succeeded.
 */
struct AuthClient {
    let baseURL: URL

    private let session: URLSession

    init(
        baseURL: URL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    /*
     * Answers ok for an address that has no account as readily as for one that
     * does -- the worker deliberately does not distinguish, so neither can
     * this. An operator who mistypes their address sees "check your email" and
     * no email arrives.
     */
    func requestSignInLink(email: String) async throws {
        var request = makeRequest(path: "magic-link")
        request.httpMethod = "POST"

        request.httpBody = try JSONEncoder().encode(
            ["email": email]
        )

        _ = try await send(request)
    }

    /*
     * The worker checks the invite code before anything else and answers ok
     * without saying whether the address already had an account -- if it did,
     * the email holds a sign-in link instead and accountName is ignored; if
     * that account is disabled, nothing is sent at all. So, exactly like
     * requestSignInLink(email:), success promises only "check your email".
     */
    func requestSignup(
        inviteCode: String,
        email: String,
        accountName: String
    ) async throws {
        var request = makeRequest(path: "signup")
        request.httpMethod = "POST"

        request.httpBody = try JSONEncoder().encode(
            [
                "inviteCode": inviteCode,
                "email": email,
                "accountName": accountName,
            ]
        )

        _ = try await send(request)
    }

    func redeem(pastedText: String) async throws -> AuthRedemption {
        guard let link = AuthLink(pastedText: pastedText) else {
            throw AuthClientError.invalidSignInLink
        }

        return try await redeem(link)
    }

    func redeem(_ link: AuthLink) async throws -> AuthRedemption {
        switch link.kind {
        case .signIn:
            return .signedIn(try await consumeSignInToken(link.token))

        case .signUp:
            return .signedUp(try await consumeSignupToken(link.token))

        case .unknown:
            /*
             * Sign-in first because it is by far the more common link. A
             * consume handed the other kind's token finds no row and returns
             * 400 before writing anything (worker/auth.ts, consumeMagicLink
             * and consumeSignup), so trying both costs one round trip and
             * cannot spend or damage either kind.
             */
            do {
                return .signedIn(try await consumeSignInToken(link.token))
            } catch let signInError
                where Self.mayBeTheOtherKindOfToken(signInError) {
                do {
                    return .signedUp(
                        try await consumeSignupToken(link.token)
                    )
                } catch let signupError
                    where Self.mayBeTheOtherKindOfToken(signupError)
                        || Self.isSignupUnavailable(signupError) {
                    /*
                     * Neither endpoint knew the token, or signup is switched
                     * off. Most bare tokens are sign-in tokens, so that
                     * endpoint's "expired or already used" is the more
                     * likely-true thing to say.
                     */
                    throw signInError
                }
            }
        }
    }

    /*
     * A 400 is what both consume endpoints answer for a token they have no
     * row for -- the only case worth retrying against the other endpoint.
     * Anything else (a 409, a 500, no network) is a real answer about this
     * token or this connection and must surface as-is.
     */
    static func mayBeTheOtherKindOfToken(_ error: Error) -> Bool {
        guard case AuthClientError.server(400, _) = error else {
            return false
        }

        return true
    }

    static func isSignupUnavailable(_ error: Error) -> Bool {
        guard case AuthClientError.server(503, _) = error else {
            return false
        }

        return true
    }

    /*
     * consumeSignup has two 500s and only one of them means "try again":
     * the other is the account having been created with the session that
     * should follow it failing to start. They differ only in their message,
     * so this matches the message -- a server rewording falls back to
     * showing the worker's own text, which also tells the user to sign in,
     * so the cost of this breaking is a less tailored message, not a wrong
     * one.
     */
    static func isAccountCreatedButNotSignedIn(
        statusCode: Int,
        message: String
    ) -> Bool {
        statusCode == 500 && message.hasPrefix("Your account is ready")
    }

    private func consumeSignupToken(
        _ token: String
    ) async throws -> SessionCredential {
        do {
            return try await consume(token, path: "signup/consume")
        } catch let AuthClientError.server(statusCode, message)
            where Self.isAccountCreatedButNotSignedIn(
                statusCode: statusCode,
                message: message
            ) {
            throw AuthClientError.accountCreatedButNotSignedIn
        }
    }

    private func consumeSignInToken(
        _ token: String
    ) async throws -> SessionCredential {
        try await consume(token, path: "magic-link/consume")
    }

    /*
     * Both consume endpoints take the same body and answer with the same
     * Set-Cookie, so one implementation serves both.
     */
    private func consume(
        _ token: String,
        path: String
    ) async throws -> SessionCredential {
        var request = makeRequest(path: path)
        request.httpMethod = "POST"

        request.httpBody = try JSONEncoder().encode(
            ["token": token]
        )

        let (_, response) = try await send(request)

        guard
            let setCookie = response.value(
                forHTTPHeaderField: "Set-Cookie"
            ),
            let credential = SessionCredential.credential(
                fromSetCookieHeader: setCookie
            )
        else {
            throw AuthClientError.missingSessionCookie
        }

        /*
         * Best effort: the sign-in has already succeeded by this point, and a
         * failure to read back the account name only costs a label in the UI.
         */
        return (try? await describe(credential)) ?? credential
    }

    /*
     * Confirms a stored credential is still live, refreshes the account
     * details attached to it, and picks up however far the session has slid
     * server-side (worker/auth.ts's getSession re-issues Set-Cookie on every
     * call, unconditionally, unlike the throttled admin routes). Throws
     * APIClientError.unauthorized -- not an AuthClientError -- for a dead
     * session, so callers can treat it exactly like a 401 from any admin
     * route.
     */
    func describe(
        _ credential: SessionCredential
    ) async throws -> SessionCredential {
        var request = makeRequest(path: "session")
        request.httpMethod = "GET"

        request.setValue(
            "\(SessionCredential.cookieName)=\(credential.token)",
            forHTTPHeaderField: "Cookie"
        )

        let (data, response) = try await send(request)

        let body = try JSONDecoder().decode(
            SessionResponse.self,
            from: data
        )

        return Self.refreshedExpiry(
            of: credential,
            from: response
        ).withAccountDetails(
            accountName: body.account.name,
            email: body.user.email
        )
    }

    /*
     * Only accepted when the Set-Cookie names the same token this credential
     * already holds -- the token itself never changes on a slide, so a
     * mismatch means something is wrong (a stale response, a proxy) and the
     * locally-known expiry is safer to keep than whatever the header said.
     */
    static func refreshedExpiry(
        of credential: SessionCredential,
        from response: HTTPURLResponse
    ) -> SessionCredential {
        guard
            let setCookie = response.value(
                forHTTPHeaderField: "Set-Cookie"
            ),
            let parsed = SessionCredential.credential(
                fromSetCookieHeader: setCookie
            ),
            parsed.token == credential.token
        else {
            return credential
        }

        return credential.withRefreshedExpiry(parsed.expiresAt)
    }

    func signOut(_ credential: SessionCredential) async throws {
        var request = makeRequest(path: "session")
        request.httpMethod = "DELETE"

        request.setValue(
            "\(SessionCredential.cookieName)=\(credential.token)",
            forHTTPHeaderField: "Cookie"
        )

        _ = try await send(request)
    }

    private func makeRequest(path: String) -> URLRequest {
        var request = URLRequest(
            url: baseURL
                .appending(path: "api")
                .appending(path: "auth")
                .appending(path: path)
        )

        request.timeoutInterval = 30

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        /*
         * handleAuthRequest refuses every state-changing /api/auth request
         * whose Origin does not match the origin it was served from. A browser
         * sets this itself; URLSession never does, so the app has to.
         */
        request.setValue(
            baseURL.originHeaderValue,
            forHTTPHeaderField: "Origin"
        )

        /*
         * The whole point of holding the session by hand. Left on, URLSession
         * would both store the Set-Cookie this flow returns and attach it to
         * later requests, so the app's real credential would be whatever the
         * shared cookie jar happened to survive with.
         */
        request.httpShouldHandleCookies = false

        return request
    }

    private func send(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message =
                (try? JSONDecoder().decode(
                    APIErrorResponse.self,
                    from: data
                ).error)
                ?? HTTPURLResponse.localizedString(
                    forStatusCode: httpResponse.statusCode
                )

            if httpResponse.statusCode == 401 {
                throw APIClientError.unauthorized(message: message)
            }

            throw AuthClientError.server(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        return (data, httpResponse)
    }
}

enum AuthRedemption: Sendable {
    case signedIn(SessionCredential)

    /** A brand-new account, so it has no events yet. */
    case signedUp(SessionCredential)

    var credential: SessionCredential {
        switch self {
        case let .signedIn(credential), let .signedUp(credential):
            return credential
        }
    }

    var feedbackTitle: String {
        switch self {
        case .signedIn:
            return "Signed in"

        case .signedUp:
            return "Account created"
        }
    }

    /*
     * A new account's event list is empty, which on its own reads like the
     * sign-in went to the wrong place. Saying so up front is the difference
     * between "nothing here yet" and "something is broken".
     */
    var feedbackDetail: String {
        switch self {
        case let .signedIn(credential):
            return credential.accountName.map { "Signed in to \($0)." }
                ?? "This iPad is now signed in to PickPic."

        case let .signedUp(credential):
            let name = credential.accountName.map { "\($0) is" }
                ?? "Your account is"

            return "\(name) ready. It's empty for now — create your first event to start uploading."
        }
    }
}

extension AuthLink {
    /*
     * The question asked before a link replaces the account this iPad is
     * already signed in to. Nothing is redeemed until it is answered, so
     * declining leaves the link unused and still valid.
     *
     * Queued uploads carry the old account's event ids, which mean nothing
     * to any other account, so they cannot continue until the iPad is signed
     * back in to the account they came from.
     */
    func accountSwitchMessage(
        currentAccount: String?,
        unfinishedUploads: Int
    ) -> String {
        let current = currentAccount ?? "another PickPic account"

        let action: String

        switch kind {
        case .signUp:
            action = "This link creates a new account and switches this iPad to it."

        case .signIn, .unknown:
            action = "This link signs this iPad in to a different account."
        }

        var message = "This iPad is signed in to \(current). \(action)"

        if unfinishedUploads > 0 {
            let uploads = unfinishedUploads == 1
                ? "1 unfinished upload belongs"
                : "\(unfinishedUploads) unfinished uploads belong"

            message += " \(uploads) to \(current) and can't upload while this iPad is signed in to another account."
        }

        return message
    }
}

private struct SessionResponse: Decodable {
    struct Account: Decodable {
        let id: String
        let name: String
    }

    struct User: Decodable {
        let id: String
        let email: String?
        let role: String
    }

    let account: Account
    let user: User
}
