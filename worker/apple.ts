import { SignJWT, createRemoteJWKSet, importPKCS8, jwtVerify } from "jose";

/*
 * Everything Sign in with Apple needs from the deployment, and nothing else.
 *
 * The split between var and secret is deliberate and not merely about how
 * sensitive each value feels. APPLE_CLIENT_ID travels in the query string of
 * every authorize redirect and APPLE_REDIRECT_URI is registered publicly with
 * Apple, so neither is a secret in any useful sense -- and keeping them as vars
 * in wrangler.jsonc means a wrong value shows up in a reviewable diff rather
 * than hiding inside `wrangler secret list`, which is exactly where a typo in a
 * redirect URI should be caught. The team id, key id and private key together
 * are what let this worker sign as Apple's client, so those three are secrets.
 */
export interface AppleEnvironment {
  /** The Services ID. Apple calls this the client id. */
  APPLE_CLIENT_ID?: string;

  /*
   * Fixed configuration rather than something derived from the incoming
   * request, unlike the magic-link URL. Apple compares this byte for byte
   * against a Return URL registered on the Services ID, on both the authorize
   * redirect and the token exchange, so it cannot vary by origin -- and
   * building it from a request's own host would additionally turn a spoofed
   * Host header into an open redirect.
   */
  APPLE_REDIRECT_URI?: string;

  APPLE_TEAM_ID?: string;

  APPLE_KEY_ID?: string;

  /** The .p8 file's contents, PEM-encoded. */
  APPLE_PRIVATE_KEY?: string;
}

/** Resolved once per request, so a half-configured deployment fails at the door. */
export interface AppleConfig {
  clientId: string;
  redirectUri: string;
  teamId: string;
  keyId: string;
  privateKey: string;
}

export interface AppleIdentity {
  /** Apple's stable subject. The natural key of an account_users row. */
  subject: string;

  /*
   * Null unless Apple both supplied an address and marked it verified. A
   * private-relay address is still a real, verified address here -- Apple
   * forwards mail to it -- but it can be turned off by the user later, which is
   * why the subject and never the address is what identifies the person.
   */
  email: string | null;
}

const APPLE_ISSUER = "https://appleid.apple.com";

const APPLE_AUTHORIZE_URL = `${APPLE_ISSUER}/auth/authorize`;

const APPLE_TOKEN_URL = `${APPLE_ISSUER}/auth/token`;

const APPLE_KEYS_URL = `${APPLE_ISSUER}/auth/keys`;

/*
 * Apple allows up to six months. Five minutes is plenty because this token is
 * minted for one immediate token exchange and thrown away -- see
 * mintAppleClientSecret for why it is never cached.
 */
const CLIENT_SECRET_TTL = "5m";

/*
 * Long enough to read Apple's consent screen and authenticate, short enough that
 * an abandoned redirect does not leave a redeemable state value lying in a
 * browser for the rest of the day.
 */
const STATE_TTL_SECONDS = 10 * 60;

/*
 * __Host- for the same reasons session.ts spells out for the session cookie: no
 * other host under pickpic.photos can set a cookie of this name that this
 * origin would then read back and compare against.
 *
 * SameSite=None is the one place this cookie has to differ from the session
 * cookie, and it is not a weakening. Apple returns the user with a cross-site
 * top-level POST (response_mode=form_post), so a Lax cookie would simply not be
 * sent and every sign-in would fail the state check. None is what makes this
 * cookie work as CSRF defence at all: its whole job is to be present on exactly
 * that cross-site POST and prove the flow started here. It carries no authority
 * of its own -- it authenticates nothing, authorises nothing, and is compared
 * against a value in the request body and then deleted.
 */
const STATE_COOKIE_NAME = "__Host-pickpic_apple_state";

let cachedJwks: ReturnType<typeof createRemoteJWKSet> | null = null;

/*
 * Apple's signing keys, memoised in the manner of access.ts's getJwks. Simpler
 * than that one because the URL is a constant rather than a per-deployment team
 * domain, so there is no cache key to invalidate.
 */
function getAppleJwks() {
  if (cachedJwks === null) {
    cachedJwks = createRemoteJWKSet(new URL(APPLE_KEYS_URL));
  }

  return cachedJwks;
}

/*
 * Null when any value is missing, so /api/auth/apple/start can answer an honest
 * 503 rather than redirecting somebody to Apple for a sign-in this deployment
 * cannot possibly complete. Whitespace-only counts as unset, matching
 * resolveAuthMode and resolveSignupInviteCode.
 */
export function resolveAppleConfig(
  environment: AppleEnvironment,
): AppleConfig | null {
  const clientId = environment.APPLE_CLIENT_ID?.trim();
  const redirectUri = environment.APPLE_REDIRECT_URI?.trim();
  const teamId = environment.APPLE_TEAM_ID?.trim();
  const keyId = environment.APPLE_KEY_ID?.trim();
  const privateKey = environment.APPLE_PRIVATE_KEY?.trim();

  if (!clientId || !redirectUri || !teamId || !keyId || !privateKey) {
    return null;
  }

  return { clientId, redirectUri, teamId, keyId, privateKey };
}

export function buildAppleAuthorizeUrl(
  config: AppleConfig,
  state: string,
): string {
  const url = new URL(APPLE_AUTHORIZE_URL);

  url.searchParams.set("client_id", config.clientId);
  url.searchParams.set("redirect_uri", config.redirectUri);
  url.searchParams.set("state", state);

  /*
   * code, not code id_token. The only identity token this worker ever trusts is
   * one it fetched itself over TLS from Apple's token endpoint; asking for one
   * in the redirect would put a second, browser-delivered copy into the flow
   * with nothing gained by trusting it.
   */
  url.searchParams.set("response_type", "code");

  /*
   * Apple requires form_post whenever name or email is requested, which is why
   * the callback is a cross-site POST and why the state cookie above is
   * SameSite=None.
   */
  url.searchParams.set("response_mode", "form_post");

  url.searchParams.set("scope", "email");

  return url.toString();
}

function serializeStateCookie(value: string, maxAgeSeconds: number): string {
  return [
    `${STATE_COOKIE_NAME}=${value}`,
    "Path=/",
    "HttpOnly",
    "Secure",
    "SameSite=None",
    `Max-Age=${maxAgeSeconds}`,
  ].join("; ");
}

export function appleStateCookieHeader(state: string): string {
  return serializeStateCookie(state, STATE_TTL_SECONDS);
}

/*
 * Sent on every callback outcome, success or failure. The state is single-use by
 * intent, and leaving a spent one in the browser would let a replayed callback
 * body get as far as the token exchange before Apple rejected the code.
 */
export function clearedAppleStateCookieHeader(): string {
  return serializeStateCookie("", 0);
}

export function readAppleStateCookie(request: Request): string | null {
  return readCookie(request, STATE_COOKIE_NAME);
}

function readCookie(request: Request, name: string): string | null {
  const header = request.headers.get("Cookie");

  if (!header) {
    return null;
  }

  for (const part of header.split(";")) {
    const separator = part.indexOf("=");

    if (separator === -1) {
      continue;
    }

    if (part.slice(0, separator).trim() !== name) {
      continue;
    }

    const value = part.slice(separator + 1).trim();

    return value.length > 0 ? value : null;
  }

  return null;
}

/*
 * Apple's client_secret is not a stored string but an ES256 JWT this worker
 * signs with the .p8 key, which is why APPLE_PRIVATE_KEY exists at all.
 *
 * Minted fresh for each exchange and deliberately not cached. Apple would allow
 * a six-month token, but a Worker isolate has no lifetime worth caching across
 * -- isolates are evicted constantly and a request can land on any machine
 * anywhere -- so a cache would be a correctness liability that is only
 * sometimes even a speedup. One ECDSA signature costs well under a millisecond
 * on a path where a human is already waiting on a redirect through Apple.
 */
export async function mintAppleClientSecret(
  config: AppleConfig,
): Promise<string> {
  /*
   * Cloudflare secrets hold multi-line values, but a .p8 pasted through a shell
   * or a CI variable often arrives with its newlines escaped, and importPKCS8
   * rejects that with an error that says nothing about why. Accepting both
   * shapes costs one replace and removes a genuinely baffling deployment
   * failure.
   */
  const pem = config.privateKey.replace(/\\n/g, "\n");

  const key = await importPKCS8(pem, "ES256");

  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.keyId })
    .setIssuer(config.teamId)
    .setSubject(config.clientId)
    .setAudience(APPLE_ISSUER)
    .setIssuedAt()
    .setExpirationTime(CLIENT_SECRET_TTL)
    .sign(key);
}

/*
 * Trades the single-use authorization code for an identity token, server to
 * server. The access and refresh tokens Apple also returns are dropped on the
 * floor: nothing in PickPic ever calls an Apple API on the user's behalf, and
 * storing a refresh token would create a credential with no use and a lifetime
 * measured in months.
 */
export async function exchangeAppleCode(
  code: string,
  config: AppleConfig,
): Promise<string> {
  const clientSecret = await mintAppleClientSecret(config);

  const response = await fetch(APPLE_TOKEN_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: config.clientId,
      client_secret: clientSecret,
      redirect_uri: config.redirectUri,
    }),
  });

  if (!response.ok) {
    /*
     * Apple's error bodies name the misconfiguration precisely -- invalid_client
     * for a wrong Services ID or key, invalid_grant for a redirect URI that does
     * not match the registered one -- and this is a server log, not a response
     * body, so quoting it leaks nothing to the caller.
     */
    throw new Error(
      `Apple rejected the code exchange with ${response.status}: ${await response.text()}`,
    );
  }

  const payload = (await response.json()) as { id_token?: unknown };

  if (typeof payload.id_token !== "string" || payload.id_token.length === 0) {
    throw new Error("Apple's token response carried no id_token.");
  }

  return payload.id_token;
}

/*
 * Verifies the identity token against Apple's published keys and pins both the
 * issuer and the audience, mirroring how access.ts verifies a Cloudflare Access
 * assertion. The audience pin is what stops an identity token minted for some
 * other Apple client from being replayed here.
 */
export async function verifyAppleIdentityToken(
  idToken: string,
  config: AppleConfig,
): Promise<AppleIdentity> {
  const { payload } = await jwtVerify(idToken, getAppleJwks(), {
    issuer: APPLE_ISSUER,
    audience: config.clientId,
  });

  const subject = typeof payload.sub === "string" ? payload.sub.trim() : "";

  if (subject.length === 0) {
    throw new Error("Apple's identity token carried no subject claim.");
  }

  return { subject, email: readVerifiedEmail(payload) };
}

/*
 * Apple sends email_verified as a boolean in some flows and as the string
 * "true" in others, and has done for years -- accepting only one shape would
 * make linking work for some accounts and silently not for others.
 *
 * An unverified address is treated as no address at all. The address is the sole
 * evidence used to attach an Apple identity to an existing account, so trusting
 * one Apple has not vouched for would let anyone who can set an arbitrary email
 * on an Apple ID claim somebody else's PickPic account.
 */
function readVerifiedEmail(payload: Record<string, unknown>): string | null {
  const email = typeof payload.email === "string" ? payload.email.trim() : "";

  if (email.length === 0) {
    return null;
  }

  const verified = payload.email_verified;

  return verified === true || verified === "true" ? email : null;
}
