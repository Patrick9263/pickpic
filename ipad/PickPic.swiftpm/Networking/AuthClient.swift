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
 * expiresAt is not decoration. worker/session.ts mints sessions with an
 * absolute thirty-day lifetime -- deliberately not sliding, so that a stolen
 * cookie dies on a fixed date however much it is used -- which means this app
 * can and will hit an expiry mid-upload. Knowing the date lets the queue warn
 * before a long shoot rather than discovering it as a 401 halfway through.
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
}

extension SessionCredential {
    /** Matches worker/session.ts's SESSION_COOKIE_NAME. */
    static let cookieName = "__Host-pickpic_session"

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

    /*
     * Pulls the sign-in token out of whatever the operator managed to paste.
     *
     * There is no universal link and no custom URL scheme here, so the way a
     * token reaches this app is that someone long-presses the link in Mail,
     * copies it, and pastes it in. In practice that clipboard can hold the
     * bare URL, the URL wrapped in punctuation, several lines of quoted email
     * body around it, or -- if they copied from a page rather than a link --
     * just the token. All four have to work, because the alternative is an
     * operator who cannot sign in staring at a field that says "invalid".
     *
     * The last occurrence wins: a quoted reply chain repeats the older link
     * above the newest one, and only the newest is unconsumed.
     */
    static func token(fromPastedText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        if let queryRange = trimmed.range(
            of: "token=",
            options: .backwards
        ) {
            return normalizedToken(
                String(trimmed[queryRange.upperBound...])
            )
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

        return normalizedToken(trimmed)
    }

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

    /*
     * Reads the session out of the worker's Set-Cookie header.
     *
     * The app parses this rather than reading HTTPCookieStorage because it
     * never lets URLSession handle cookies at all (see the type comment), so
     * nothing would be in that store to read. Max-Age is the authority on the
     * expiry: it comes from the same SESSION_TTL_SECONDS the row in
     * auth_sessions was written with, so the two cannot drift.
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
            That does not look like a PickPic sign-in link. Copy the link \
            from the email and paste it again.
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

    func signIn(withPastedLink pastedText: String) async throws
        -> SessionCredential {
        guard
            let token = SessionCredential.token(
                fromPastedText: pastedText
            )
        else {
            throw AuthClientError.invalidSignInLink
        }

        var request = makeRequest(path: "magic-link/consume")
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
     * Confirms a stored credential is still live and refreshes the account
     * details attached to it. Throws APIClientError.unauthorized -- not an
     * AuthClientError -- for a dead session, so callers can treat it exactly
     * like a 401 from any admin route.
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

        let (data, _) = try await send(request)

        let body = try JSONDecoder().decode(
            SessionResponse.self,
            from: data
        )

        return credential.withAccountDetails(
            accountName: body.account.name,
            email: body.user.email
        )
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
