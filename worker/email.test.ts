import { describe, expect, it, vi, afterEach } from "vitest";
import { escapeHtml, sendGalleryEmail } from "./email.ts";

/*
 * Until #224 this module could state that nothing interpolated caller-supplied
 * text. Gallery mail broke that on arrival -- it carries a photo filename, an
 * event title and a display name, all of which a stranger holding a share link
 * can choose -- and it goes out from the domain every customer's sign-in
 * deliverability depends on. So the escaping is tested rather than assumed.
 */
describe("escapeHtml", () => {
  it("escapes the five characters that can break out of markup", () => {
    expect(escapeHtml(`<a href="x" title='y'>&</a>`)).toBe(
      "&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;&lt;/a&gt;",
    );
  });

  /*
   * Ampersand has to be replaced first. Doing it after the others would find
   * the ones they just introduced and turn &lt; into &amp;lt;, which renders as
   * the literal text "&lt;" rather than a less-than sign.
   */
  it("does not double-escape the entities it introduces", () => {
    expect(escapeHtml("<")).toBe("&lt;");
    expect(escapeHtml("&lt;")).toBe("&amp;lt;");
  });

  it("leaves ordinary text alone", () => {
    expect(escapeHtml("DSC01015.ARW")).toBe("DSC01015.ARW");
  });
});

describe("sendGalleryEmail", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  function captureSend(): { body: () => Record<string, string> } {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("{}", { status: 200 }));

    return {
      body: () =>
        JSON.parse(String(fetchMock.mock.calls[0][1]?.body)) as Record<
          string,
          string
        >,
    };
  }

  it("escapes attacker-controlled text in the HTML body", async () => {
    const capture = captureSend();

    await sendGalleryEmail(
      { RESEND_API_KEY: "re_test" } as Parameters<typeof sendGalleryEmail>[0],
      {
        kind: "raw-ready",
        to: "guest@example.com",
        url: "https://pickpic.photos/api/galleries/s/photos/p/raw?t=abc",
        eventTitle: "<script>alert(1)</script>",
        filename: `DSC"01015'&.ARW`,
        displayName: "<img onerror=alert(1)>",
      },
      false,
    );

    const body = capture.body();

    expect(body.html).not.toContain("<script>");
    expect(body.html).not.toContain("<img");
    expect(body.html).toContain("&lt;script&gt;");
    expect(body.html).toContain("&amp;");
  });

  /*
   * The text part is not markup, so it must *not* be escaped -- a recipient
   * whose client shows the plain-text alternative should see the real filename,
   * not a mouthful of entities.
   */
  it("leaves the plain-text body unescaped", async () => {
    const capture = captureSend();

    await sendGalleryEmail(
      { RESEND_API_KEY: "re_test" } as Parameters<typeof sendGalleryEmail>[0],
      {
        kind: "raw-ready",
        to: "guest@example.com",
        url: "https://pickpic.photos/api/galleries/s/photos/p/raw?t=abc",
        eventTitle: "Ada & Bob",
        filename: "DSC01015.ARW",
        displayName: "Ada",
      },
      false,
    );

    const body = capture.body();

    expect(body.text).toContain("Ada & Bob");
    expect(body.text).not.toContain("&amp;");
  });

  /*
   * Gallery mail goes to event guests who never asked for a PickPic account and
   * may well mark it as spam. Keeping it off the sign-in sender is what stops
   * that costing a customer their ability to log in.
   */
  it("sends from the gallery address, not the sign-in one", async () => {
    const capture = captureSend();

    await sendGalleryEmail(
      { RESEND_API_KEY: "re_test" } as Parameters<typeof sendGalleryEmail>[0],
      {
        kind: "raw-confirm",
        to: "guest@example.com",
        url: "https://pickpic.photos/api/galleries/s/raw-confirm?t=abc",
        eventTitle: "Test Event",
        filename: "DSC01015.ARW",
        displayName: "Ada",
      },
      false,
    );

    expect(capture.body().from).not.toContain("login@");
    expect(capture.body().from).toContain("photos@pickpic.photos");
  });

  /*
   * Off localhost a missing key has to be an error rather than a log line, or
   * an unconfigured deployment would write working download links into the
   * observability log. What the caller does with the error is its own business
   * -- worker/index.ts swallows it for gallery mail.
   */
  it("throws rather than logging a link when it cannot send", async () => {
    await expect(
      sendGalleryEmail(
        {} as Parameters<typeof sendGalleryEmail>[0],
        {
          kind: "raw-ready",
          to: "guest@example.com",
          url: "https://pickpic.photos/api/galleries/s/photos/p/raw?t=secret",
          eventTitle: "Test Event",
          filename: "DSC01015.ARW",
          displayName: "Ada",
        },
        false,
      ),
    ).rejects.toThrow("RESEND_API_KEY is not configured.");
  });
});
