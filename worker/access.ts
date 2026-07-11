import { createRemoteJWKSet, jwtVerify } from "jose";

export interface AccessEnvironment {
  TEAM_DOMAIN?: string;
  POLICY_AUD?: string;
}

let cachedTeamDomain: string | null = null;

let cachedJwks: ReturnType<typeof createRemoteJWKSet> | null = null;

function isLocalRequest(request: Request): boolean {
  const hostname = new URL(request.url).hostname;

  return (
    hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]"
  );
}

function forbidden(error: string): Response {
  return Response.json(
    { error },
    {
      status: 403,
      headers: {
        "Cache-Control": "no-store",
      },
    },
  );
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
): Promise<Response | null> {
  /*
   * Wrangler local development does not run behind
   * Cloudflare Access.
   */
  if (isLocalRequest(request)) {
    return null;
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
    await jwtVerify(token, getJwks(teamDomain), {
      issuer: teamDomain,
      audience: policyAudience,
    });

    return null;
  } catch (error) {
    console.error("Cloudflare Access token validation failed:", error);

    return forbidden("Your photographer session is invalid or expired.");
  }
}
