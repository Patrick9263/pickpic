import type { TenantEnv } from "./tenancy.ts";

/*
 * RESEND_API_KEY is a secret (`wrangler secret put`), never a var in
 * wrangler.jsonc. MAGIC_LINK_FROM is an ordinary var and must be an address on a
 * domain verified with Resend, otherwise every send is rejected.
 */
export type EmailEnvironment = TenantEnv & {
  RESEND_API_KEY?: string;
  MAGIC_LINK_FROM?: string;
};

const DEFAULT_FROM = "PickPic <login@pickpic.photos>";

const RESEND_ENDPOINT = "https://api.resend.com/emails";

export interface MagicLinkEmail {
  to: string;
  url: string;
  expiresInMinutes: number;
}

/*
 * Sends the link, or prints it, and throws if it can do neither.
 *
 * allowConsoleFallback is true only for a request that arrived on localhost.
 * Without that condition an unconfigured production deployment would write
 * working login links into the observability log, which is a worse failure than
 * refusing to sign anyone in -- so off localhost a missing key is a 500, not a
 * quiet downgrade.
 */
export async function sendMagicLinkEmail(
  environment: EmailEnvironment,
  email: MagicLinkEmail,
  allowConsoleFallback: boolean,
): Promise<void> {
  const apiKey = environment.RESEND_API_KEY?.trim();

  if (!apiKey) {
    if (!allowConsoleFallback) {
      throw new Error("RESEND_API_KEY is not configured.");
    }

    console.log(`[auth] magic link for ${email.to}: ${email.url}`);

    return;
  }

  const response = await fetch(RESEND_ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: environment.MAGIC_LINK_FROM?.trim() || DEFAULT_FROM,
      to: [email.to],
      subject: "Your PickPic sign-in link",
      text: renderText(email),
      html: renderHtml(email),
    }),
  });

  if (!response.ok) {
    /*
     * The body is logged rather than returned: Resend reports an unverified
     * sending domain and a malformed recipient the same way, and neither belongs
     * in a response that must stay identical for known and unknown addresses.
     */
    console.error(
      `Resend rejected a magic-link email with status ${response.status}:`,
      await response.text(),
    );

    throw new Error("The sign-in email could not be sent.");
  }
}

function renderText(email: MagicLinkEmail): string {
  return [
    "Sign in to PickPic:",
    "",
    email.url,
    "",
    `This link works once and expires in ${email.expiresInMinutes} minutes.`,
    "If you did not ask to sign in, you can ignore this email.",
  ].join("\n");
}

function renderHtml(email: MagicLinkEmail): string {
  /*
   * The href is a URL this worker just built from its own origin and a
   * base64url token, so it contains no character that needs escaping here.
   */
  return [
    '<div style="font-family: system-ui, sans-serif; font-size: 16px; line-height: 1.5;">',
    "<p>Sign in to PickPic:</p>",
    `<p><a href="${email.url}">Open PickPic</a></p>`,
    `<p>This link works once and expires in ${email.expiresInMinutes} minutes.</p>`,
    "<p>If you did not ask to sign in, you can ignore this email.</p>",
    "</div>",
  ].join("");
}
