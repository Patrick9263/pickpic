import {
  createExecutionContext,
  env,
  waitOnExecutionContext,
} from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import worker from "./index.ts";
import {
  captureEmails,
  clearTestData,
  deliverRawPhoto,
  insertEvent,
  insertPhoto,
  insertRawRequest,
  linkFromEmail,
  type CapturedEmail,
} from "./test-fixtures.ts";
import { galleryRequest } from "./test-request.ts";

/*
 * An exported handler is typed against an *incoming* request, which carries a
 * populated `cf` object a plain `new Request()` does not. A type-level
 * narrowing only, with no runtime effect.
 */
const IncomingRequest = Request<unknown, IncomingRequestCfProperties>;

/*
 * #224: a RAW is entitled by a confirmed email address rather than by the
 * browser it was asked from, so the same person collecting on a laptop after
 * requesting on a phone is one request instead of two. The second of those was
 * fulfilled-and-never-downloaded, which kept isRawReclaimable's awaitingCount
 * veto true and pinned ~120 MB for the full fourteen days (#222).
 *
 * These go through the real routes rather than the helpers underneath them,
 * because the parts most worth protecting are the ones that only exist in the
 * chain: that no raw_requests row is written before the address is proved, and
 * that a retired token stops working.
 */

const EVENT_ID = "event-delivery";
const PHOTO_ID = "photo-delivery";
const OTHER_PHOTO_ID = "photo-delivery-other";
const SHARE_TOKEN = "share-delivery";
const VISITOR_TOKEN = "visitor-token-delivery-phone";
const OTHER_VISITOR_TOKEN = "visitor-token-delivery-laptop";
const GUEST_EMAIL = "guest@example.com";

const RAW_REQUEST_PATH = `/api/galleries/${SHARE_TOKEN}/photos/${PHOTO_ID}/raw-request`;

let mail: ReturnType<typeof captureEmails>;

beforeEach(async () => {
  await clearTestData();
  mail = captureEmails();

  await insertEvent({
    id: EVENT_ID,
    shareToken: SHARE_TOKEN,
    status: "ready",
    rawRequestsEnabled: true,
  });
  await insertPhoto({
    id: PHOTO_ID,
    eventId: EVENT_ID,
    originalFilename: "DSC01015.ARW",
  });
  await insertPhoto({ id: OTHER_PHOTO_ID, eventId: EVENT_ID });
});

afterEach(() => {
  mail.restore();
});

interface RawRequestBody {
  requested: boolean;
  confirmationPending?: boolean;
  email?: string;
  rawDownload?: unknown;
}

function requestRaw(
  visitorToken: string,
  email: string,
  path = RAW_REQUEST_PATH,
): Promise<{ status: number; body: RawRequestBody }> {
  return galleryRequest<RawRequestBody>("PUT", path, {
    json: { displayName: "Guest", email },
    headers: { "X-PickPic-Visitor": visitorToken },
  });
}

/** The path-and-query half of a captured link, which is what a route match sees. */
function pathOf(email: CapturedEmail): string {
  const url = new URL(linkFromEmail(email));

  return `${url.pathname}${url.search}`;
}

/*
 * Driven directly rather than through galleryRequest, for the reason that
 * helper's sibling in gallery.workers.test.ts already documents: the
 * downloaded_at stamp rides on a waitUntil that only settles once the body has
 * drained, and the shared helper awaits the execution context before a caller
 * can attach a reader. Reading first is the order this route needs, and the
 * order a real client uses.
 */
async function driveTokenDownload(path: string): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new IncomingRequest(`https://pickpic.photos${path}`),
    env,
    ctx,
  );

  await response.arrayBuffer();
  await waitOnExecutionContext(ctx);

  return response;
}

async function countRawRequests(): Promise<number> {
  const row = await env.DB.prepare(
    "SELECT COUNT(*) AS total FROM raw_requests",
  ).first<{ total: number }>();

  return row?.total ?? 0;
}

describe("confirming the address before a request exists", () => {
  /*
   * The property the whole design rests on. A typo must not create a request:
   * an uncollectable request holds the RAW open for the full TTL, and the
   * viewer has no reason to come back and discover why.
   */
  it("writes no raw_requests row until the link is clicked", async () => {
    const result = await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);

    expect(result.body).toMatchObject({
      requested: false,
      confirmationPending: true,
      email: GUEST_EMAIL,
    });
    expect(await countRawRequests()).toBe(0);

    expect(mail.sent).toHaveLength(1);
    expect(mail.sent[0].to).toEqual([GUEST_EMAIL]);
    expect(mail.sent[0].subject).toContain("DSC01015.ARW");
  });

  it("creates the request and returns to the gallery when redeemed", async () => {
    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);

    const redeemed = await galleryRequest("GET", pathOf(mail.sent[0]));

    expect(redeemed.status).toBe(302);
    expect(redeemed.response.headers.get("Location")).toBe(
      `/g/${SHARE_TOKEN}?photo=${PHOTO_ID}`,
    );
    expect(await countRawRequests()).toBe(1);
  });

  it("refuses a token that has already been redeemed", async () => {
    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);

    const path = pathOf(mail.sent[0]);

    await galleryRequest("GET", path);
    const replayed = await galleryRequest("GET", path);

    expect(replayed.status).toBe(400);
    expect(await countRawRequests()).toBe(1);
  });

  it("refuses an expired token", async () => {
    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);

    await env.DB.prepare("UPDATE raw_request_confirmations SET expires_at = ?")
      .bind("2020-01-01T00:00:00.000Z")
      .run();

    const redeemed = await galleryRequest("GET", pathOf(mail.sent[0]));

    expect(redeemed.status).toBe(400);
    expect(await countRawRequests()).toBe(0);
  });

  /*
   * The token names its own event, so pairing it with somebody else's share
   * token must not work -- otherwise a confirmation for one gallery would be a
   * way into another.
   */
  it("refuses a token paired with a different gallery's share token", async () => {
    await insertEvent({
      id: "event-elsewhere",
      shareToken: "share-elsewhere",
      status: "ready",
      rawRequestsEnabled: true,
    });

    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);

    const crossed = pathOf(mail.sent[0]).replace(
      SHARE_TOKEN,
      "share-elsewhere",
    );

    expect((await galleryRequest("GET", crossed)).status).toBe(400);
    expect(await countRawRequests()).toBe(0);
  });

  /*
   * The address, not the browser, is what has been proved -- so collecting a
   * second photo from the same shoot is one click rather than another trip
   * through the mail.
   */
  it("skips confirmation once the address has a request in the event", async () => {
    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);
    await galleryRequest("GET", pathOf(mail.sent[0]));

    const second = await requestRaw(
      VISITOR_TOKEN,
      GUEST_EMAIL,
      `/api/galleries/${SHARE_TOKEN}/photos/${OTHER_PHOTO_ID}/raw-request`,
    );

    expect(second.body).toMatchObject({
      requested: true,
      confirmationPending: false,
    });
    expect(await countRawRequests()).toBe(2);
  });

  it("requires an address at all", async () => {
    const result = await galleryRequest<{ error: string }>(
      "PUT",
      RAW_REQUEST_PATH,
      {
        json: { displayName: "Guest" },
        headers: { "X-PickPic-Visitor": VISITOR_TOKEN },
      },
    );

    expect(result.status).toBe(400);
    expect(await countRawRequests()).toBe(0);
    expect(mail.sent).toHaveLength(0);
  });
});

describe("the address is the identity, not the browser", () => {
  /*
   * #222 itself. Two browsers, one person: the phone's row used to be left
   * fulfilled and uncollected forever, which vetoed every reclaim and actually
   * *extended* the hold each time they asked again.
   */
  it("attaches a second browser to the existing request", async () => {
    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);
    await galleryRequest("GET", pathOf(mail.sent[0]));

    const fromLaptop = await requestRaw(OTHER_VISITOR_TOKEN, GUEST_EMAIL);

    expect(fromLaptop.body.requested).toBe(true);
    expect(await countRawRequests()).toBe(1);

    /*
     * And it stays the phone's row. Moving it to whoever asked last would take
     * the in-page download away from the browser that actually asked.
     */
    const row = await env.DB.prepare(
      `
        SELECT v.visitor_token AS visitorToken
        FROM raw_requests r
        INNER JOIN gallery_visitors v ON v.id = r.visitor_id
        WHERE r.photo_id = ?
      `,
    )
      .bind(PHOTO_ID)
      .first<{ visitorToken: string }>();

    expect(row?.visitorToken).toBe(VISITOR_TOKEN);
  });

  /*
   * The instant-fulfil version of the test above. getGalleryRawPhoto's
   * header-based route only ever recognises the row's actual visitor_id, so
   * a second browser that does not own it cannot use that route -- claiming
   * a download is ready for it would be a dead link the moment it tried.
   * Device independence has to come from its own mail instead.
   */
  it("gives a second browser its own mail rather than a dead in-page link", async () => {
    await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      originalFilename: "DSC01015.ARW",
    });

    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);
    await galleryRequest("GET", pathOf(mail.sent[0]));

    const sentBefore = mail.sent.length;

    const fromLaptop = await requestRaw(OTHER_VISITOR_TOKEN, GUEST_EMAIL);

    expect(fromLaptop.body.requested).toBe(true);
    expect(fromLaptop.body.rawDownload ?? null).toBeNull();

    /*
     * It still needs a way to actually get the file, so it gets a mail of its
     * own rather than nothing.
     */
    expect(mail.sent.length).toBe(sentBefore + 1);

    const laptopsOwnLink = pathOf(mail.sent[mail.sent.length - 1]);

    expect((await driveTokenDownload(laptopsOwnLink)).status).toBe(200);

    /*
     * And the honesty check: the laptop's own visitor token genuinely cannot
     * reach the file through the header route, confirming the null above
     * was not just cosmetic.
     */
    const laptopHeaderAttempt = await galleryRequest(
      "GET",
      RAW_REQUEST_PATH.replace("/raw-request", "/raw"),
      { headers: { "X-PickPic-Visitor": OTHER_VISITOR_TOKEN } },
    );

    expect(laptopHeaderAttempt.status).toBe(404);
  });

  /*
   * Rows written before migration 0023 carry no address. They must be adopted
   * rather than duplicated, or the first request after the upgrade would
   * recreate the very duplicate this is removing.
   */
  it("adopts a legacy row that predates the address column", async () => {
    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      email: null,
    });
    await insertRawRequest({
      photoId: OTHER_PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      email: GUEST_EMAIL,
    });

    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);

    expect(await countRawRequests()).toBe(2);

    const row = await env.DB.prepare(
      "SELECT email FROM raw_requests WHERE photo_id = ?",
    )
      .bind(PHOTO_ID)
      .first<{ email: string | null }>();

    expect(row?.email).toBe(GUEST_EMAIL);
  });

  /*
   * The merge must not throw away the record of who collected the bytes --
   * downloaded_at is the only place that exists (#220), and a collected row
   * cannot hold storage open anyway, so keeping it costs nothing.
   */
  it("keeps a superseded row that records a collection", async () => {
    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: OTHER_VISITOR_TOKEN,
      email: GUEST_EMAIL,
    });
    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      email: "typo@example.com",
      fulfilledAt: "2026-01-01T00:00:00.000Z",
      downloadedAt: "2026-01-02T00:00:00.000Z",
    });

    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);

    expect(await countRawRequests()).toBe(2);
  });
});

describe("a plain duplicate of an already-fulfilled request", () => {
  /*
   * writeRawRequest documents this as a no-op -- "falls through all three
   * arms and changes nothing" -- but the delivery mail used to be sent
   * unconditionally whenever fulfilledAt was non-null, regardless of which
   * arm ran. sendRawReadyEmail mints a fresh token and overwrites
   * download_token_hash every time it runs, so a viewer re-asking for a file
   * they already have a working link for (a second tab, a reload, the same
   * browser twice) silently broke that link with no warning.
   */
  it("does not re-mail the download link or retire the one already sent", async () => {
    await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      originalFilename: "DSC01015.ARW",
    });

    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);
    await galleryRequest("GET", pathOf(mail.sent[0]));

    const path = pathOf(mail.sent[mail.sent.length - 1]);
    const sentBefore = mail.sent.length;

    const duplicate = await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);

    expect(duplicate.body.requested).toBe(true);
    expect(mail.sent.length).toBe(sentBefore);
    expect((await driveTokenDownload(path)).status).toBe(200);
  });
});

describe("correcting a mistyped address", () => {
  /*
   * A corrected address is an unproven one, so it goes through confirmation
   * just like the first. That is the point: without it the typo hazard would
   * simply move to the correction path.
   */
  it("confirms the corrected address before re-pointing anything", async () => {
    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      email: "alcie@example.com",
    });

    const corrected = await requestRaw(VISITOR_TOKEN, "alice@example.com");

    expect(corrected.body).toMatchObject({ confirmationPending: true });
    expect(await countRawRequests()).toBe(1);

    /*
     * And once proved, it re-points the row this browser already had rather
     * than inserting beside it. This is the branch that would otherwise be a
     * crash rather than a bug: the corrected address has no row to attach to,
     * so the only uniqueness left to violate is the surviving primary key.
     */
    await galleryRequest("GET", pathOf(mail.sent[0]));

    expect(await countRawRequests()).toBe(1);

    const row = await env.DB.prepare(
      "SELECT email FROM raw_requests WHERE photo_id = ?",
    )
      .bind(PHOTO_ID)
      .first<{ email: string }>();

    expect(row?.email).toBe("alice@example.com");
  });

  /*
   * The security half. If the RAW had already been delivered, a working
   * download link is sitting in the wrong inbox, and overwriting the hash is
   * the only thing that takes it away.
   */
  it("kills the link already sent to the wrong address", async () => {
    await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      originalFilename: "DSC01015.ARW",
    });
    await insertRawRequest({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      visitorToken: VISITOR_TOKEN,
      email: "alcie@example.com",
      fulfilledAt: new Date().toISOString(),
      downloadTokenHash: "hash-of-the-link-sent-to-the-typo",
    });

    await requestRaw(VISITOR_TOKEN, "alice@example.com");
    await galleryRequest("GET", pathOf(mail.sent[0]));

    const row = await env.DB.prepare(
      "SELECT download_token_hash AS hash FROM raw_requests WHERE photo_id = ?",
    )
      .bind(PHOTO_ID)
      .first<{ hash: string | null }>();

    expect(row?.hash).not.toBe("hash-of-the-link-sent-to-the-typo");

    /*
     * The corrected address gets a working link of its own, which is what
     * proves the hash was replaced rather than merely cleared -- clearing it
     * would leave the right recipient with nothing.
     */
    const delivery = mail.sent[mail.sent.length - 1];

    expect(delivery.to).toEqual(["alice@example.com"]);
    expect((await driveTokenDownload(pathOf(delivery))).status).toBe(200);
  });
});

describe("downloading with the emailed token", () => {
  /*
   * Requesting a photo whose RAW is already in R2 is the instant-fulfil path,
   * which reaches a real delivery mail without driving the iPad's ~120 MB
   * upload route. Confirmation runs first, exactly as it would for a viewer.
   */
  async function deliverAndCapture(): Promise<string> {
    await deliverRawPhoto({
      photoId: PHOTO_ID,
      eventId: EVENT_ID,
      originalFilename: "DSC01015.ARW",
    });

    await requestRaw(VISITOR_TOKEN, GUEST_EMAIL);
    await galleryRequest("GET", pathOf(mail.sent[0]));

    return pathOf(mail.sent[mail.sent.length - 1]);
  }

  it("serves the file to a browser that has never seen the gallery", async () => {
    const path = await deliverAndCapture();

    const download = await driveTokenDownload(path);

    expect(download.status).toBe(200);
    expect(download.headers.get("Content-Disposition")).toContain(
      "DSC01015.ARW",
    );

    /*
     * And the collection is recorded against the request, which is what lets
     * the reclaim free the bytes -- a download that never stamped would pin
     * them for the full TTL, which is the #222 failure in a new place.
     */
    const row = await env.DB.prepare(
      "SELECT downloaded_at AS downloadedAt FROM raw_requests WHERE photo_id = ?",
    )
      .bind(PHOTO_ID)
      .first<{ downloadedAt: string | null }>();

    expect(row?.downloadedAt).not.toBeNull();
  });

  it("refuses a token pointed at a different photo", async () => {
    const path = await deliverAndCapture();

    const crossed = path.replace(PHOTO_ID, OTHER_PHOTO_ID);

    expect((await galleryRequest("GET", crossed)).status).toBe(404);
  });

  it("refuses a token that is simply wrong", async () => {
    const path = await deliverAndCapture();

    const wrong = path.replace(/t=.*$/, "t=not-a-real-token");

    expect((await galleryRequest("GET", wrong)).status).toBe(404);
  });

  /*
   * The link is only as good as the file behind it. The reclaim runs on the
   * iPad's poll rather than a timer, so honouring the stated expiry here is
   * what stops the link outliving the window the viewer was told about.
   */
  it("refuses a token once the delivery window has passed", async () => {
    const path = await deliverAndCapture();

    await env.DB.prepare("UPDATE raw_requests SET fulfilled_at = ?")
      .bind("2020-01-01T00:00:00.000Z")
      .run();

    expect((await galleryRequest("GET", path)).status).toBe(404);
  });

  /*
   * Answering a browser navigation with a JSON body reads as a broken link
   * rather than an expired one, which sends the viewer to the photographer
   * instead of back to the gallery.
   */
  it("renders a page rather than JSON when the link is dead", async () => {
    const path = await deliverAndCapture();

    await env.DB.prepare("UPDATE raw_requests SET fulfilled_at = ?")
      .bind("2020-01-01T00:00:00.000Z")
      .run();

    const dead = await galleryRequest("GET", path);

    expect(dead.response.headers.get("Content-Type")).toContain("text/html");
  });
});

describe("the send caps", () => {
  /*
   * Anyone with a share link can cause mail to be sent to an address they
   * typed. The per-visitor cap is the half that actually bounds that, since
   * fifty different typos are fifty fresh per-address budgets.
   */
  it("stops one browser mailing an unbounded number of addresses", async () => {
    for (let index = 0; index < 20; index += 1) {
      await requestRaw(VISITOR_TOKEN, `guest${index}@example.com`);
    }

    expect(mail.sent.length).toBeLessThanOrEqual(12);
  });

  /*
   * And it says nothing about having stopped. A response that reported the
   * suppression would tell an abuser exactly when to start again, while a
   * viewer who hit it honestly should still go and look at their inbox.
   */
  it("answers a capped request the same way as an accepted one", async () => {
    let last: RawRequestBody | null = null;

    for (let index = 0; index < 20; index += 1) {
      last = (await requestRaw(VISITOR_TOKEN, `guest${index}@example.com`))
        .body;
    }

    expect(last).toMatchObject({ requested: false, confirmationPending: true });
  });
});
