import { createRemoteJWKSet, jwtVerify } from "jose";

export interface AccessEnvironment {
  TEAM_DOMAIN?: string;
  POLICY_AUD?: string;
}

/*
 * provider/subject together are the natural key of account_users
 * (auth_provider, auth_subject).
 */
interface PrincipalIdentity {
  provider: string;

  subject: string;

  email: string | null;
}

/*
 * A request that Cloudflare Access vouched for: the operator's SSO identity on
 * admin.pickpic.photos, or the iPad's service token.
 *
 * account_users holds no row for either -- their identifiers are Cloudflare
 * configuration and deliberately absent from this repository -- so this variant
 * carries no account and resolves to the bootstrap account. See
 * resolveAccountForPrincipal.
 */
export interface AccessPrincipal extends PrincipalIdentity {
  kind: "access";

  /*
   * 'cloudflare_access' for an SSO identity, or
   * 'cloudflare_access_service_token' for a machine identity such as the iPad.
   */
  provider: "cloudflare_access" | "cloudflare_access_service_token";

  /** True on localhost, where Access does not run at all. */
  isLocalDevelopment: boolean;
}

/*
 * A request carrying one of our own session cookies. Resolving the session
 * already joined account_users, so the account is known here and must be used --
 * falling back to the bootstrap account for a session would hand a stranger the
 * operator's photos.
 */
export interface SessionPrincipal extends PrincipalIdentity {
  kind: "session";

  accountId: string;

  accountUserId: string;

  sessionId: string;

  role: string;
}

/*
 * The verified identity behind an admin request.
 *
 * A discriminated union rather than one interface with an optional accountId,
 * so that a handler which forgets to distinguish the two is a compile error
 * instead of a silent fall-through into the bootstrap account's data.
 */
export type AdminPrincipal = AccessPrincipal | SessionPrincipal;

/*
 * A discriminated union rather than `Response | AdminPrincipal`, so a caller
 * cannot accidentally test it backwards and let an unverified request through.
 */
export type AdminAccessResult =
  { ok: true; principal: AdminPrincipal } | { ok: false; response: Response };

let cachedTeamDomain: string | null = null;

let cachedJwks: ReturnType<typeof createRemoteJWKSet> | null = null;

/*
 * Localhost is the one origin no Cloudflare product sits in front of, so it is
 * both where Access is skipped and the only place a magic link may be printed to
 * the console instead of emailed.
 */
export function isLocalRequest(request: Request): boolean {
  const hostname = new URL(request.url).hostname;

  return (
    hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]"
  );
}

export function forbidden(error: string): AdminAccessResult {
  return {
    ok: false,
    response: Response.json(
      { error },
      {
        status: 403,
        headers: {
          "Cache-Control": "no-store",
        },
      },
    ),
  };
}

function getJwks(teamDomain: string) {
  if (cachedJwks === null || cachedTeamDomain !== teamDomain) {
    cachedTeamDomain = teamDomain;

    cachedJwks = createRemoteJWKSet(
      new URL(`${teamDomain}/cdn-cgi/access/certs`),
    );
  }

  return cachedJwks;
}

export async function requireAdminAccess(
  request: Request,
  environment: AccessEnvironment,
): Promise<AdminAccessResult> {
  /*
   * Wrangler local development does not run behind
   * Cloudflare Access.
   */
  if (isLocalRequest(request)) {
    return {
      ok: true,
      principal: {
        kind: "access",
        provider: "cloudflare_access",
        subject: "local-development",
        email: null,
        isLocalDevelopment: true,
      },
    };
  }

  const teamDomain = environment.TEAM_DOMAIN?.replace(/\/+$/, "");

  const policyAudience = environment.POLICY_AUD?.trim();

  if (!teamDomain || !policyAudience) {
    console.error("Cloudflare Access environment variables are missing.");

    return forbidden("Photographer authentication is not configured.");
  }

  const token = request.headers.get("Cf-Access-Jwt-Assertion");

  if (!token) {
    return forbidden("Photographer authentication is required.");
  }

  try {
    const { payload } = await jwtVerify(token, getJwks(teamDomain), {
      issuer: teamDomain,
      audience: policyAudience,
    });

    /*
     * Access issues service-token assertions with common_name set to the
     * token's client id and no email claim, and SSO assertions with sub and
     * email. The iPad authenticates as a service token, so both shapes reach
     * this worker.
     */
    const commonName =
      typeof payload.common_name === "string" ? payload.common_name.trim() : "";

    const principal: AccessPrincipal =
      commonName.length > 0
        ? {
            kind: "access",
            provider: "cloudflare_access_service_token",
            subject: commonName,
            email: null,
            isLocalDevelopment: false,
          }
        : {
            kind: "access",
            provider: "cloudflare_access",
            subject: typeof payload.sub === "string" ? payload.sub.trim() : "",
            email: typeof payload.email === "string" ? payload.email : null,
            isLocalDevelopment: false,
          };

    if (principal.subject.length === 0) {
      console.error("Cloudflare Access token carried no usable subject claim.");

      return forbidden("Your photographer session is invalid or expired.");
    }

    return { ok: true, principal };
  } catch (error) {
    console.error("Cloudflare Access token validation failed:", error);

    return forbidden("Your photographer session is invalid or expired.");
  }
}
