import Foundation
import Testing

@testable import PickPic

/*
 * The two pure pieces of the sign-in path: turning whatever the operator
 * pasted into a token, and turning the worker's Set-Cookie into a credential
 * with an expiry. Both sit between a person with a clipboard and the only
 * credential this app has, so both are worth pinning down without a network.
 */
struct SessionCredentialTests {
    private static let signInLink =
        "https://app.pickpic.photos/sign-in?token=abcDEF123-_xyz"

    private static let token = "abcDEF123-_xyz"

    @Test
    func readsTheTokenFromASignInLink() {
        #expect(
            SessionCredential.token(fromPastedText: Self.signInLink)
                == Self.token
        )
    }

    @Test
    func readsABareToken() {
        #expect(
            SessionCredential.token(fromPastedText: Self.token)
                == Self.token
        )
    }

    @Test
    func ignoresSurroundingWhitespace() {
        #expect(
            SessionCredential.token(
                fromPastedText: "\n  \(Self.signInLink)  \n"
            ) == Self.token
        )
    }

    /*
     * Mail wraps links in punctuation and quoted replies carry text on both
     * sides of the URL, so the token has to survive being embedded rather
     * than only being pasted alone.
     */
    @Test
    func readsATokenSurroundedByEmailText() {
        #expect(
            SessionCredential.token(
                fromPastedText: """
                Sign in to PickPic:
                <\(Self.signInLink)>
                This link expires in 15 minutes.
                """
            ) == Self.token
        )
    }

    @Test
    func stopsAtTheEndOfTheTokenWhenMoreQueryFollows() {
        #expect(
            SessionCredential.token(
                fromPastedText: "\(Self.signInLink)&utm_source=email"
            ) == Self.token
        )
    }

    /*
     * A reply chain repeats the older, already-consumed link above the newest
     * one. Redeeming the first match would report "already used" for a link
     * that was in fact still good.
     */
    @Test
    func prefersTheLastTokenWhenSeveralArePasted() {
        #expect(
            SessionCredential.token(
                fromPastedText: """
                https://app.pickpic.photos/sign-in?token=olderTOKEN
                https://app.pickpic.photos/sign-in?token=newerTOKEN
                """
            ) == "newerTOKEN"
        )
    }

    @Test(arguments: [
        "",
        "   ",
        "https://app.pickpic.photos/sign-in",
        "https://app.pickpic.photos/sign-in?token=",
        "not a token at all",
    ])
    func rejectsTextThatCarriesNoToken(pasted: String) {
        #expect(SessionCredential.token(fromPastedText: pasted) == nil)
    }

    /*
     * The token says nothing about which consume endpoint it belongs to, so
     * the link's path is the only routing signal -- and a wrong route is
     * reported as "expired or already used" for a link that is still good.
     */
    @Test(arguments: [
        ("https://app.pickpic.photos/sign-in?token=abc", AuthLinkKind.signIn),
        ("https://app.pickpic.photos/sign-up?token=abc", .signUp),
        ("https://app.pickpic.photos/sign-up/?token=abc", .signUp),
        ("https://app.pickpic.photos/sign-up?ref=mail&token=abc", .signUp),
        ("<https://app.pickpic.photos/sign-up?token=abc>.", .signUp),
        ("\"https://app.pickpic.photos/sign-in?token=abc\"", .signIn),
        ("https://app.pickpic.photos/?token=abc", .unknown),
        ("https://app.pickpic.photos/g/share?token=abc", .unknown),
        ("abc", .unknown),
    ])
    func classifiesALinkByItsPath(
        pasted: String,
        kind: AuthLinkKind
    ) {
        #expect(
            AuthLink(pastedText: pasted)
                == AuthLink(token: "abc", kind: kind)
        )
    }

    @Test
    func classifiesASignupLinkInsideQuotedEmailText() {
        #expect(
            AuthLink(
                pastedText: """
                Confirm your PickPic account:
                > https://app.pickpic.photos/sign-up?token=abc
                This link expires in 30 minutes.
                """
            ) == AuthLink(token: "abc", kind: .signUp)
        )
    }

    /*
     * The kind comes from the same, last, occurrence as the token -- a
     * reply quoting an old sign-in link above a newer sign-up link must
     * route to signup.
     */
    @Test
    func takesTheKindFromTheLastLink() {
        #expect(
            AuthLink(
                pastedText: """
                https://app.pickpic.photos/sign-in?token=olderTOKEN
                https://app.pickpic.photos/sign-up?token=newerTOKEN
                """
            ) == AuthLink(token: "newerTOKEN", kind: .signUp)
        )
    }

    /*
     * A "?" on an earlier line is not this token's query, so it must not
     * lend this token a path.
     */
    @Test
    func ignoresAQuestionMarkFromAnotherLine() {
        #expect(
            AuthLink(
                pastedText: """
                Did you mean https://app.pickpic.photos/sign-up?
                token=abc
                """
            ) == AuthLink(token: "abc", kind: .unknown)
        )
    }

    @Test(arguments: [
        "",
        "https://app.pickpic.photos/sign-up",
        "https://app.pickpic.photos/sign-up?token=",
        "not a token at all",
    ])
    func rejectsLinksThatCarryNoToken(pasted: String) {
        #expect(AuthLink(pastedText: pasted) == nil)
    }

    @Test
    func retriesOnlyAnUnknownTokenAgainstTheOtherEndpoint() {
        #expect(
            AuthClient.mayBeTheOtherKindOfToken(
                AuthClientError.server(statusCode: 400, message: "Expired.")
            )
        )

        for error: Error in [
            AuthClientError.server(statusCode: 409, message: "Exists."),
            AuthClientError.server(statusCode: 500, message: "Oops."),
            AuthClientError.invalidResponse,
            URLError(.notConnectedToInternet),
        ] {
            #expect(!AuthClient.mayBeTheOtherKindOfToken(error))
        }
    }

    @Test
    func recognisesAnAccountCreatedWithoutASession() {
        #expect(
            AuthClient.isAccountCreatedButNotSignedIn(
                statusCode: 500,
                message: """
                Your account is ready, but signing you in failed. Open the \
                sign-in page and enter your email.
                """
            )
        )

        // The other 500 consumeSignup returns means nothing was created.
        #expect(
            !AuthClient.isAccountCreatedButNotSignedIn(
                statusCode: 500,
                message: "Your account could not be created. Try again."
            )
        )
    }

    @Test
    func namesTheAccountAndStrandedUploadsBeforeSwitching() {
        let link = AuthLink(token: "abc", kind: .signUp)

        let message = link.accountSwitchMessage(
            currentAccount: "Studio A",
            currentEmail: "a@example.com",
            unfinishedUploads: 3,
            uploadsInProgress: 0
        )

        #expect(message.contains("signed in to Studio A (a@example.com)."))
        #expect(message.contains("creates a new account"))
        #expect(message.contains("3 unfinished uploads belong to Studio A (a@example.com)"))

        #expect(
            link.accountSwitchMessage(
                currentAccount: "Studio A",
                currentEmail: nil,
                unfinishedUploads: 1,
                uploadsInProgress: 0
            ).contains("1 unfinished upload belongs to Studio A and")
        )

        let signIn = AuthLink(token: "abc", kind: .signIn).accountSwitchMessage(
            currentAccount: nil,
            currentEmail: nil,
            unfinishedUploads: 0,
            uploadsInProgress: 0
        )

        #expect(!signIn.contains("upload"))
        #expect(signIn.contains("signed in to a PickPic account."))
    }

    /*
     * A sign-in link may well be for the account already signed in -- the
     * iPad can't tell before redeeming it -- so the alert must not assert
     * that it is for a different one.
     */
    @Test
    func signInSwitchWordingStaysConditional() {
        let message = AuthLink(token: "abc", kind: .signIn)
            .accountSwitchMessage(
                currentAccount: "PickPic",
                currentEmail: "p@example.com",
                unfinishedUploads: 0,
                uploadsInProgress: 0
            )

        #expect(
            message == "This iPad is signed in to PickPic (p@example.com). If this link is for a different account, this iPad will switch to it."
        )
    }

    @Test
    func readsTheSessionCookie() {
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let credential = SessionCredential.credential(
            fromSetCookieHeader: """
            __Host-pickpic_session=\(Self.token); Path=/; HttpOnly; \
            Secure; SameSite=Lax; Max-Age=2592000
            """,
            receivedAt: receivedAt
        )

        #expect(credential?.token == Self.token)

        #expect(
            credential?.expiresAt
                == receivedAt.addingTimeInterval(2_592_000)
        )
    }

    /*
     * Sign-out is expressed as the same cookie with an empty value and
     * Max-Age=0. Treating that as a credential would store a token that
     * authenticates nothing.
     */
    @Test
    func rejectsAClearedSessionCookie() {
        #expect(
            SessionCredential.credential(
                fromSetCookieHeader:
                    "__Host-pickpic_session=; Path=/; HttpOnly; Max-Age=0"
            ) == nil
        )
    }

    @Test
    func rejectsACookieWithADifferentName() {
        #expect(
            SessionCredential.credential(
                fromSetCookieHeader:
                    "some_other_cookie=\(Self.token); Path=/; Max-Age=2592000"
            ) == nil
        )
    }

    /*
     * Without Max-Age there is no expiry to store, and guessing one would
     * either lock the app out early or let it keep trying past the real
     * expiry.
     */
    @Test
    func rejectsACookieWithNoMaxAge() {
        #expect(
            SessionCredential.credential(
                fromSetCookieHeader:
                    "__Host-pickpic_session=\(Self.token); Path=/; HttpOnly"
            ) == nil
        )
    }

    @Test
    func treatsAPassedExpiryAsExpired() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let credential = SessionCredential(
            token: Self.token,
            expiresAt: now.addingTimeInterval(-1)
        )

        #expect(credential.isExpired(asOf: now))
        #expect(!credential.isExpiringSoon(asOf: now))
    }

    @Test
    func warnsInsideTheRenewalWindowButNotOutsideIt() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let expiringSoon = SessionCredential(
            token: Self.token,
            expiresAt: now.addingTimeInterval(
                SessionCredential.renewalWarningInterval - 60
            )
        )

        let fresh = SessionCredential(
            token: Self.token,
            expiresAt: now.addingTimeInterval(
                SessionCredential.renewalWarningInterval + 60
            )
        )

        #expect(expiringSoon.isExpiringSoon(asOf: now))
        #expect(!fresh.isExpiringSoon(asOf: now))
        #expect(!fresh.isExpired(asOf: now))
    }

    /*
     * The credential is stored as JSON in the Keychain, so a round trip is
     * the same thing that happens between one launch and the next.
     */
    @Test
    func survivesAKeychainRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let original = SessionCredential(
            token: Self.token,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            accountName: "PickPic",
            email: "photographer@example.com"
        )

        let restored = try decoder.decode(
            SessionCredential.self,
            from: try encoder.encode(original)
        )

        #expect(restored == original)
    }

    /*
     * A credential saved before SessionCredential carried an account has to
     * keep loading from the Keychain -- failing to decode it would sign the
     * iPad out on upgrade -- and has to come back with no account, so
     * refreshSession() knows to fill it in.
     */
    @Test
    func decodesAKeychainValueSavedBeforeAccountIDsExisted() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let stored = """
            {
                "token": "\(Self.token)",
                "expiresAt": "2030-01-01T00:00:00Z",
                "accountName": "PickPic",
                "email": "photographer@example.com"
            }
            """

        let credential = try decoder.decode(
            SessionCredential.self,
            from: Data(stored.utf8)
        )

        #expect(credential.token == Self.token)
        #expect(credential.accountName == "PickPic")
        #expect(credential.accountID == nil)
    }

    @Test
    func keepsTheAccountWhenTheExpirySlides() {
        let credential = SessionCredential(
            token: Self.token,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            accountID: "acct-1"
        )

        let slid = credential.withRefreshedExpiry(
            Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(slid.accountID == "acct-1")
    }

    // MARK: - Switch warning

    @Test
    func noWarningWithNothingUnfinished() {
        #expect(
            AuthLink.unfinishedWorkWarning(
                currentAccount: "PickPic",
                unfinishedUploads: 0,
                uploadsInProgress: 0
            ) == nil
        )
    }

    @Test
    func warnsThatUnfinishedUploadsWaitForTheAccount() throws {
        let warning = try #require(
            AuthLink.unfinishedWorkWarning(
                currentAccount: "PickPic",
                unfinishedUploads: 2,
                uploadsInProgress: 0
            )
        )

        #expect(warning.contains("2 unfinished uploads belong to PickPic"))
        #expect(warning.contains("once you sign back in to PickPic"))
        #expect(!warning.contains("Uploading stops"))
    }

    /*
     * The switch revokes this account's session, so a running transfer is
     * the one thing that visibly stops -- it has to be said up front.
     */
    @Test
    func warnsThatARunningUploadStops() throws {
        let warning = try #require(
            AuthLink.unfinishedWorkWarning(
                currentAccount: "PickPic",
                unfinishedUploads: 1,
                uploadsInProgress: 1
            )
        )

        #expect(warning.contains("1 unfinished upload belongs"))
        #expect(warning.contains("Uploading stops when you switch"))
    }

    @Test
    func describesAnAccountByNameAndEmail() {
        #expect(
            AuthLink.accountDescription(
                name: "PickPic",
                email: "photographer@example.com"
            ) == "PickPic (photographer@example.com)"
        )
        #expect(
            AuthLink.accountDescription(name: nil, email: nil)
                == "a PickPic account"
        )
    }

    // MARK: - AccountScope

    @Test
    func untaggedWorkBelongsToWhoeverIsSignedIn() {
        #expect(
            AccountScope.owns(currentAccountID: "acct-a", workAccountID: nil)
        )
        #expect(
            AccountScope.owns(currentAccountID: nil, workAccountID: nil)
        )
    }

    @Test
    func taggedWorkBelongsOnlyToItsOwnAccount() {
        #expect(
            AccountScope.owns(
                currentAccountID: "acct-a",
                workAccountID: "acct-a"
            )
        )
        #expect(
            !AccountScope.owns(
                currentAccountID: "acct-b",
                workAccountID: "acct-a"
            )
        )
    }

    /*
     * A credential that has not learned its account yet must not guess:
     * guessing wrong is the cross-account upload this rule exists to stop.
     */
    @Test
    func anUnknownAccountOwnsNoTaggedWork() {
        #expect(
            !AccountScope.owns(currentAccountID: nil, workAccountID: "acct-a")
        )
    }

    @Test
    func anUnknownAccountUsesTheLegacyCacheFile() {
        #expect(
            AccountScope.eventCacheFilename(for: nil) == "events-cache.json"
        )
    }

    @Test
    func aUUIDAccountIDIsUsedAsIsInItsCacheFilename() {
        let accountID = "2f1d6c1e-8a1b-4c55-9d3e-7f0a6b2c9e41"

        #expect(
            AccountScope.eventCacheFilename(for: accountID)
                == "events-cache-\(accountID).json"
        )
    }

    /*
     * Hashed rather than filtered, so ids that differ only in characters a
     * filename cannot hold still get separate files.
     */
    @Test
    func unsafeAccountIDsAreHashedIntoDistinctFilenames() {
        let first = AccountScope.eventCacheFilename(for: "../a")
        let second = AccountScope.eventCacheFilename(for: "/a")

        #expect(first != second)
        #expect(!first.contains("/"))
        #expect(!second.contains("/"))
        #expect(first.hasPrefix("events-cache-"))
    }

    /*
     * isSameOriginRequest in worker/auth.ts compares this against
     * new URL(request.url).origin, which never carries a path.
     */
    @Test(arguments: [
        "https://app.pickpic.photos",
        "https://app.pickpic.photos/",
    ])
    func buildsAnOriginHeaderWithNoTrailingPath(base: String) throws {
        let url = try #require(URL(string: base))

        #expect(url.originHeaderValue == "https://app.pickpic.photos")
    }

    @Test
    func keepsANonDefaultPortInTheOriginHeader() throws {
        let url = try #require(URL(string: "http://localhost:8787/"))

        #expect(url.originHeaderValue == "http://localhost:8787")
    }

    @Test(arguments: [401])
    func classifiesAStatusAsNeedingSignIn(statusCode: Int) {
        #expect(APIClientError.isUnauthorized(statusCode: statusCode))

        #expect(
            APIClientError.isUnauthorized(
                APIClientError.forStatus(
                    statusCode: statusCode,
                    message: "Your session has expired. Sign in again."
                )
            )
        )
    }

    @Test(arguments: [400, 403, 404, 500, 503])
    func leavesOtherStatusesAsServerErrors(statusCode: Int) {
        #expect(!APIClientError.isUnauthorized(statusCode: statusCode))

        #expect(
            !APIClientError.isUnauthorized(
                APIClientError.forStatus(
                    statusCode: statusCode,
                    message: "Nope."
                )
            )
        )
    }

    /*
     * GET /api/auth/session re-issues Set-Cookie unconditionally, with
     * however far the row has slid -- unlike the throttled admin routes,
     * where it appears only when the expiry actually moved. This is the
     * pure piece AuthClient.describe(_:) spends on every call: does a
     * response's Set-Cookie move this credential's stored expiry.
     */
    @Test
    func refreshesExpiryFromAMatchingSetCookie() throws {
        let credential = SessionCredential(
            token: Self.token,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let response = try makeResponse(
            setCookie:
                "__Host-pickpic_session=\(Self.token); Path=/; HttpOnly; "
                + "Secure; SameSite=Lax; Max-Age=2592000"
        )

        let refreshed = AuthClient.refreshedExpiry(
            of: credential,
            from: response
        )

        #expect(refreshed.token == credential.token)
        #expect(refreshed.expiresAt != credential.expiresAt)
    }

    /*
     * The token never changes on a slide, so a Set-Cookie naming a
     * different one is not this credential's refresh -- keep the expiry
     * that is already trusted rather than adopt an unrelated one.
     */
    @Test
    func keepsTheOriginalExpiryWhenTheCookieNamesADifferentToken() throws {
        let credential = SessionCredential(
            token: Self.token,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let response = try makeResponse(
            setCookie:
                "__Host-pickpic_session=someOtherToken; Path=/; "
                + "Max-Age=2592000"
        )

        let refreshed = AuthClient.refreshedExpiry(
            of: credential,
            from: response
        )

        #expect(refreshed == credential)
    }

    @Test
    func keepsTheOriginalExpiryWithNoSetCookieHeader() throws {
        let credential = SessionCredential(
            token: Self.token,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let response = try makeResponse(setCookie: nil)

        let refreshed = AuthClient.refreshedExpiry(
            of: credential,
            from: response
        )

        #expect(refreshed == credential)
    }

    /*
     * refreshSession() skips its save on equivalence, and every save restarts
     * App.swift's automatic sync task (#384), so these pin both directions:
     * read-to-read jitter must not count as a change, and a real slide or a
     * newly learned account must.
     */
    private static let refreshBase = SessionCredential(
        token: token,
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        accountID: "account-1",
        accountName: "Studio",
        email: "studio@example.test"
    )

    @Test
    func treatsExpiryJitterAsEquivalent() {
        let reread = Self.refreshBase.withRefreshedExpiry(
            Self.refreshBase.expiresAt.addingTimeInterval(-42)
        )

        #expect(Self.refreshBase.isEquivalent(to: reread))
    }

    @Test
    func treatsADaySlideAsAChange() {
        let slid = Self.refreshBase.withRefreshedExpiry(
            Self.refreshBase.expiresAt.addingTimeInterval(24 * 60 * 60)
        )

        #expect(!Self.refreshBase.isEquivalent(to: slid))
    }

    @Test
    func treatsANewlyLearnedAccountAsAChange() {
        let unknown = SessionCredential(
            token: Self.token,
            expiresAt: Self.refreshBase.expiresAt
        )

        #expect(!unknown.isEquivalent(to: Self.refreshBase))
    }

    @Test
    func treatsARenamedAccountAsAChange() {
        let renamed = Self.refreshBase.withAccountDetails(
            accountID: "account-1",
            accountName: "Renamed Studio",
            email: "studio@example.test"
        )

        #expect(!Self.refreshBase.isEquivalent(to: renamed))
    }

    private func makeResponse(
        setCookie: String?
    ) throws -> HTTPURLResponse {
        try #require(
            HTTPURLResponse(
                url: URL(string: "https://app.pickpic.photos/api/auth/session")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: setCookie.map { ["Set-Cookie": $0] } ?? [:]
            )
        )
    }
}
