import { createRemoteJWKSet, jwtVerify } from "jose";

export interface AccessEnvironment {
  TEAM_DOMAIN?: string;
  POLICY_AUD?: string;
}

/*
 * The verified identity behind an admin request.
 *
 * provider/subject together are the natural key of account_users
 * (auth_provider, auth_subject), which is how a principal will be mapped to an
 * account once real user authentication exists.
 */
export interface AdminPrincipal {
  /*
   * 'cloudflare_access' for an SSO identity, or
   * 'cloudflare_access_service_token' for a machine identity such as the iPad.
   */
  provider: string;

  /*
   * The Access JWT 'sub' for an SSO identity, or 'common_name' -- the service
   * token's client id -- for a service token.
   */
  subject: string;

  email: string | null;

  /** True on localhost, where Access does not run at all. */
  isLocalDevelopment: boolean;
}

/*
 * A discriminated union rather than `Response | AdminPrincipal`, so a caller
 * cannot accidentally test it backwards and let an unverified request through.
 */
export type AdminAccessResult =
  { ok: true; principal: AdminPrincipal } | { ok: false; response: Response };

let cachedTeamDomain: string | null = null;

let cachedJwks: ReturnType<typeof createRemoteJWKSet> | null = null;

function isLocalRequest(request: Request): boolean {
  const hostname = new URL(request.url).hostname;

  return (
    hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]"
  );
}

function forbidden(error: string): AdminAccessResult {
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

    const principal: AdminPrincipal =
      commonName.length > 0
        ? {
            provider: "cloudflare_access_service_token",
            subject: commonName,
            email: null,
            isLocalDevelopment: false,
          }
        : {
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
