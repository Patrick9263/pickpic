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
}
