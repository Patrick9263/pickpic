import type { TenantEnv } from "./tenancy.ts";

/*
 * RESEND_API_KEY is a secret (`wrangler secret put`), never a var in
 * wrangler.jsonc. The two From addresses are ordinary vars and must each be an
 * address on a domain verified with Resend, otherwise every send is rejected.
 *
 * The key is needed on all three deployments now, not just the one serving
 * /api/auth/*: gallery mail (#224) is sent by the public worker when a RAW is
 * already in R2 at request time, and by the admin/app worker when the iPad
 * delivers one.
 */
export type EmailEnvironment = TenantEnv & {
  RESEND_API_KEY?: string;
  MAGIC_LINK_FROM?: string;
  RAW_DELIVERY_FROM?: string;
};

const DEFAULT_AUTH_FROM = "PickPic <login@pickpic.photos>";

/*
 * A separate sender from the sign-in address on purpose. Gallery mail goes to
 * event guests who never asked for a PickPic account and may well mark it as
 * spam; sign-in mail is transactional and its deliverability is load-bearing
 * for every customer. Same verified domain, so this costs nothing to add, but
 * the two reputations stay apart.
 */
const DEFAULT_RAW_DELIVERY_FROM = "PickPic <photos@pickpic.photos>";

const RESEND_ENDPOINT = "https://api.resend.com/emails";

/*
 * Every value interpolated into an HTML body must go through this. It is the
 * one rule this module has: the studio name a signup collects, and the photo
 * filename, event title and display name a gallery mail carries, are all
 * attacker-controlled, and this mail goes out from the domain every customer's
 * sign-in deliverability depends on.
 *
 * Ampersand first, or it would double-escape the entities the later
 * replacements introduce.
 */
export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

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
 * Nothing here interpolates caller-supplied text. Gallery mail further down
 * does, and goes through escapeHtml for it.
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

/** Sends the sign-in link, or prints it on localhost. See sendEmail below. */
export async function sendMagicLinkEmail(
  environment: EmailEnvironment,
  email: MagicLinkEmail,
  allowConsoleFallback: boolean,
): Promise<void> {
  await sendEmail(
    environment,
    {
      kind: email.kind,
      from: environment.MAGIC_LINK_FROM?.trim() || DEFAULT_AUTH_FROM,
      to: email.to,
      subject: COPY[email.kind].subject,
      text: renderText(email),
      html: renderHtml(email),
    },
    allowConsoleFallback
      ? () =>
          console.log(`[auth] ${email.kind} link for ${email.to}: ${email.url}`)
      : null,
  );
}

interface OutboundEmail {
  /** Only ever used in log lines, so a missing key or a rejection is traceable. */
  kind: string;
  from: string;
  to: string;
  subject: string;
  text: string;
  html: string;
}

/*
 * The shared Resend call. Sends, or runs the caller's fallback, and throws if it
 * can do neither.
 *
 * consoleFallback is non-null only for a request that arrived on localhost.
 * Without that condition an unconfigured production deployment would write
 * working links into the observability log, which is a worse failure than
 * refusing to send -- so off localhost a missing key is an error, not a quiet
 * downgrade. What the caller does with that error differs: auth turns it into a
 * 500, gallery mail swallows it, because a RAW that was delivered successfully
 * must not be reported as a failed upload just because the notification bounced.
 */
async function sendEmail(
  environment: EmailEnvironment,
  email: OutboundEmail,
  consoleFallback: (() => void) | null,
): Promise<void> {
  const apiKey = environment.RESEND_API_KEY?.trim();

  if (!apiKey) {
    if (!consoleFallback) {
      throw new Error("RESEND_API_KEY is not configured.");
    }

    consoleFallback();

    return;
  }

  const response = await fetch(RESEND_ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: email.from,
      to: [email.to],
      subject: email.subject,
      text: email.text,
      html: email.html,
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

/*
 * Gallery mail (#224), which is a different animal from the two above and is
 * kept as its own union rather than a third AuthEmailKind. The auth kinds share
 * a shape -- a single-use URL that signs you in and expires in minutes -- and
 * neither of these does: "raw-confirm" proves an address and grants no session,
 * "raw-ready" is a download link that lives as long as the file does. Folding
 * them into that Record would have meant copy fields that mean nothing for half
 * its members.
 *
 * The recipient is an event guest, not a customer, and every one of these
 * carries text somebody else typed -- hence escapeHtml on every interpolation.
 */
export type GalleryEmailKind = "raw-confirm" | "raw-ready";

export interface GalleryEmail {
  kind: GalleryEmailKind;
  to: string;
  url: string;
  eventTitle: string;
  filename: string;
  displayName: string;
}

export async function sendGalleryEmail(
  environment: EmailEnvironment,
  email: GalleryEmail,
  allowConsoleFallback: boolean,
): Promise<void> {
  const subject =
    email.kind === "raw-confirm"
      ? `Confirm your request for ${email.filename}`
      : `Your RAW file is ready: ${email.filename}`;

  await sendEmail(
    environment,
    {
      kind: email.kind,
      from: environment.RAW_DELIVERY_FROM?.trim() || DEFAULT_RAW_DELIVERY_FROM,
      to: email.to,
      subject,
      text: renderGalleryText(email),
      html: renderGalleryHtml(email),
    },
    allowConsoleFallback
      ? () =>
          console.log(
            `[gallery] ${email.kind} link for ${email.to}: ${email.url}`,
          )
      : null,
  );
}

/*
 * Split out so the copy can be read in one place, and so the two renderers
 * cannot drift on wording the way branching inside each of them would allow.
 */
function galleryCopy(email: GalleryEmail): {
  lead: string;
  cta: string;
  note: string;
  ignore: string;
} {
  if (email.kind === "raw-confirm") {
    return {
      lead: `${email.displayName}, confirm this address to request the original file for ${email.filename} from ${email.eventTitle}.`,
      cta: "Confirm my request",
      note: "This link works once and expires in 24 hours. Until you use it, nothing has been requested.",
      ignore:
        "If you did not ask for this file, you can ignore this email -- no request has been made.",
    };
  }

  return {
    lead: `${email.filename} from ${email.eventTitle} is ready to download.`,
    cta: "Download the original file",
    /*
     * No expiry date here on purpose. It is knowable, but the true one depends
     * on every live request for the photo, and #225 is where stating it gets
     * decided.
     */
    note: "The file is large, so download it somewhere with room for it. This link is for you alone -- anyone you forward it to can download the file.",
    ignore:
      "If you did not request this file, you can ignore this email and the link will expire on its own.",
  };
}

function renderGalleryText(email: GalleryEmail): string {
  const copy = galleryCopy(email);

  return [copy.lead, "", email.url, "", copy.note, copy.ignore].join("\n");
}

function renderGalleryHtml(email: GalleryEmail): string {
  const copy = galleryCopy(email);

  /*
   * The href is built by this worker from its own origin, an encodeURIComponent
   * share token and photo id, and a base64url token, so it carries nothing that
   * needs escaping -- but it is escaped anyway, because the day someone adds a
   * caller-supplied query parameter here is not the day to discover that this
   * one line was the exception.
   */
  return [
    '<div style="font-family: system-ui, sans-serif; font-size: 16px; line-height: 1.5;">',
    `<p>${escapeHtml(copy.lead)}</p>`,
    `<p><a href="${escapeHtml(email.url)}">${escapeHtml(copy.cta)}</a></p>`,
    `<p>${escapeHtml(copy.note)}</p>`,
    `<p>${escapeHtml(copy.ignore)}</p>`,
    "</div>",
  ].join("");
}
