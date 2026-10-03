import Foundation

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
     * A sign-in token says nothing about whose it is until it is redeemed,
     * so the wording stays conditional: tapping a fresh link for the account
     * already signed in is the common case, and it switches nothing.
     *
     * The email goes beside the account name because a studio name alone
     * can read as something else entirely -- the bootstrap account is called
     * "PickPic", the app's own name.
     *
     * Queued uploads carry the old account's event ids, which mean nothing
     * to any other account, so they cannot continue until the iPad is signed
     * back in to the account they came from.
     */
    func accountSwitchMessage(
        currentAccount: String?,
        currentEmail: String?,
        unfinishedUploads: Int,
        uploadsInProgress: Int
    ) -> String {
        let current = Self.accountDescription(
            name: currentAccount,
            email: currentEmail
        )

        let action: String

        switch kind {
        case .signUp:
            action = "This link creates a new account and switches this iPad to it."

        case .signIn, .unknown:
            action = "If this link is for a different account, this iPad will switch to it."
        }

        var message = "This iPad is signed in to \(current). \(action)"

        if let warning = Self.unfinishedWorkWarning(
            currentAccount: current,
            unfinishedUploads: unfinishedUploads,
            uploadsInProgress: uploadsInProgress
        ) {
            message += " \(warning)"
        }

        return message
    }

    static func accountDescription(
        name: String?,
        email: String?
    ) -> String {
        switch (name, email) {
        case let (name?, email?):
            return "\(name) (\(email))"

        case let (name?, nil):
            return name

        case let (nil, email?):
            return email

        case (nil, nil):
            return "a PickPic account"
        }
    }

    /*
     * What switching does to the current account's queue. Shared by the
     * switch alert and the Account sheet's "Sign In to Another Account", so
     * the warning reads the same whichever way the switch starts -- and the
     * sheet shows it before a link has even been requested.
     *
     * A warning, not a gate. Links expire in 15 or 30 minutes and a shoot can
     * take hours to upload on a poor connection, so "finish first" would
     * mostly mean "the link has expired"; and some work cannot finish at
     * all without help (offline events, failed frames, a full storage cap).
     *
     * An upload running right now is called out separately because it is
     * the one immediate effect: the switch revokes this account's session,
     * so the transfer stops partway. Photos already sent stay sent.
     */
    static func unfinishedWorkWarning(
        currentAccount: String,
        unfinishedUploads: Int,
        uploadsInProgress: Int
    ) -> String? {
        guard unfinishedUploads > 0 else {
            return nil
        }

        let uploads = unfinishedUploads == 1
            ? "1 unfinished upload belongs"
            : "\(unfinishedUploads) unfinished uploads belong"

        var warning = "\(uploads) to \(currentAccount) and can't upload while this iPad is signed in to another account."

        if uploadsInProgress > 0 {
            warning += " Uploading stops when you switch; photos already uploaded are kept."
        }

        warning += " They can upload again once you sign back in to \(currentAccount)."

        return warning
    }
}
