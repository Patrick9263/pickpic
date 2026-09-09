import { expect, test } from "@playwright/test";
import { seedGallery, type SeededGallery } from "./seed";

const VISITOR_DISPLAY_NAME = "E2E Tester";

let fixture: SeededGallery;

test.beforeEach(async ({ request }, testInfo) => {
  fixture = await seedGallery(request, `E2E gallery ${testInfo.title}`);
});

/*
 * Both hearting (the first time) and commenting ask for a display name via
 * `window.prompt` -- see GalleryPage.tsx's `resolveDisplayName`. Accepting it
 * once per test is enough; the name then lives in localStorage for the rest
 * of that page's session.
 */
function acceptDisplayNamePrompt(page: import("@playwright/test").Page): void {
  page.once("dialog", (dialog) => {
    void dialog.accept(VISITOR_DISPLAY_NAME);
  });
}

test("loads a gallery share link and renders its photos", async ({ page }) => {
  await page.goto(`/g/${fixture.shareToken}`);

  await expect(
    page.getByRole("button", { name: `Open ${fixture.originalFilename}` }),
  ).toBeVisible();
  await expect(page.getByText("1 photo")).toBeVisible();
});

test("hearting a photo persists across reload", async ({ page }) => {
  await page.goto(`/g/${fixture.shareToken}`);

  const heartButton = page.getByRole("button", {
    name: `Request an edit of ${fixture.originalFilename}`,
  });

  acceptDisplayNamePrompt(page);
  await heartButton.click();

  const heartedButton = page.getByRole("button", {
    name: `Remove edit request for ${fixture.originalFilename}`,
  });
  await expect(heartedButton).toHaveAttribute("aria-pressed", "true");
  await expect(heartedButton).toContainText("1");

  /*
   * A heart is an edit request, not a social reaction (see CLAUDE.md) --
   * persisting it depends on the browser-local visitor token in
   * localStorage, sent back as X-PickPic-Visitor, so a reload has to keep
   * showing the same viewer's own edit request without asking again.
   */
  await page.reload();

  await expect(
    page.getByRole("button", {
      name: `Remove edit request for ${fixture.originalFilename}`,
    }),
  ).toHaveAttribute("aria-pressed", "true");
});

test("still renders the gallery when site data/storage is blocked", async ({
  page,
}) => {
  /*
   * iOS Safari's "Block All Cookies" setting throws a SecurityError on
   * merely *accessing* window.localStorage, not just on getItem/setItem.
   * GalleryPage's useState initializers read it during first render, so
   * before the storage-safe helpers in galleryHelpers.ts this crashed with
   * no error boundary to catch it, leaving a viewer with a blank page.
   */
  await page.addInitScript(() => {
    Object.defineProperty(window, "localStorage", {
      configurable: true,
      get() {
        throw new DOMException("Blocked", "SecurityError");
      },
    });
  });

  await page.goto(`/g/${fixture.shareToken}`);

  await expect(
    page.getByRole("button", { name: `Open ${fixture.originalFilename}` }),
  ).toBeVisible();
});

test("leaves a comment on a photo", async ({ page }) => {
  await page.goto(`/g/${fixture.shareToken}`);

  await page
    .getByRole("button", { name: `Open ${fixture.originalFilename}` })
    .click();

  const commentBox = page.getByLabel("Leave a comment or edit note");
  await commentBox.waitFor();
  await commentBox.fill("Please brighten this one up a little.");

  acceptDisplayNamePrompt(page);
  await page.getByRole("button", { name: "Post comment" }).click();

  await expect(page.getByText(VISITOR_DISPLAY_NAME)).toBeVisible();
  await expect(
    page.getByText("Please brighten this one up a little."),
  ).toBeVisible();
});
