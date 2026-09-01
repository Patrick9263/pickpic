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

/*
 * Which of the two links this message carries. Both are a single-use URL that
 * signs the recipient in; they differ only in whether an account exists on the
 * other side of it.
 */
export type AuthEmailKind = "sign-in" | "sign-up";

export interface MagicLinkEmail {
  kind: AuthEmailKind;
  to: string;
  url: string;
  expiresInMinutes: number;
}

/*
 * The only thing the two emails do not share. Keying a Record on the union
 * rather than branching inside each renderer makes adding a third kind -- Sign
 * in with Apple, an address change -- a compile error until its copy is
 * written, instead of a silent fall-through to the sign-in wording.
 *
 * Nothing here interpolates caller-supplied text, and nothing may start to. The
 * studio name a signup collects is attacker-controlled, renderHtml does not
 * escape, and this mail goes out from the domain every customer's sign-in
 * deliverability depends on.
 */
const COPY: Record<
  AuthEmailKind,
  { subject: string; lead: string; cta: string; ignore: string }
> = {
  "sign-in": {
    subject: "Your PickPic sign-in link",
    lead: "Sign in to PickPic:",
    cta: "Open PickPic",
    ignore: "If you did not ask to sign in, you can ignore this email.",
  },
  "sign-up": {
    subject: "Confirm your PickPic account",
    lead: "Finish creating your PickPic account:",
    cta: "Create my account",
    ignore:
      "If you did not ask to create an account, you can ignore this email -- nothing has been created yet.",
  },
};

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

    console.log(`[auth] ${email.kind} link for ${email.to}: ${email.url}`);

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
      subject: COPY[email.kind].subject,
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
      `Resend rejected a ${email.kind} email with status ${response.status}:`,
      await response.text(),
    );

    /*
     * Generic on purpose. Every caller substitutes its own user-facing string,
     * and those strings have to match across callers -- see the sendFailureMessage
     * parameter in worker/auth.ts -- so nothing should ever surface this one.
     */
    throw new Error("The email could not be sent.");
  }
}

function renderText(email: MagicLinkEmail): string {
  const copy = COPY[email.kind];

  return [
    copy.lead,
    "",
    email.url,
    "",
    `This link works once and expires in ${email.expiresInMinutes} minutes.`,
    copy.ignore,
  ].join("\n");
}

function renderHtml(email: MagicLinkEmail): string {
  /*
   * The href is a URL this worker just built from its own origin and a
   * base64url token, so it contains no character that needs escaping here.
   */
  const copy = COPY[email.kind];

  return [
    '<div style="font-family: system-ui, sans-serif; font-size: 16px; line-height: 1.5;">',
    `<p>${copy.lead}</p>`,
    `<p><a href="${email.url}">${copy.cta}</a></p>`,
    `<p>This link works once and expires in ${email.expiresInMinutes} minutes.</p>`,
    `<p>${copy.ignore}</p>`,
    "</div>",
  ].join("");
}
