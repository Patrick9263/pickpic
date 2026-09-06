import { beforeEach, describe, expect, it } from "vitest";
import { findDuplicatePhoto } from "./index.ts";
import type { AccountScope } from "./tenancy.ts";
import {
  bootstrapScope,
  clearTestData,
  insertEvent,
  insertPhoto,
  testSha256,
} from "./test-fixtures.ts";

/*
 * Duplicate detection is server-authoritative -- the iPad preflight only decides
 * which files are worth hashing, and is allowed to be wrong. These cover the
 * rule findDuplicatePhoto actually implements, including the two ways it is
 * asymmetric: it matches the final hash as well as the original, and it is
 * scoped to one event because Sony bodies reset frame counters and the same
 * source file legitimately recurs across shoots.
 */

const EVENT_ID = "event-duplicates";
const OTHER_EVENT_ID = "event-duplicates-other";

let scope: AccountScope;

beforeEach(async () => {
  await clearTestData();

  scope = await bootstrapScope();

  await insertEvent({ id: EVENT_ID, shareToken: "share-duplicates" });
  await insertEvent({
    id: OTHER_EVENT_ID,
    shareToken: "share-duplicates-other",
  });
});

describe("findDuplicatePhoto", () => {
  it("matches a stored original hash in the same event", async () => {
    await insertPhoto({
      id: "photo-original",
      eventId: EVENT_ID,
      sourceSha256: testSha256("original"),
    });

    const duplicate = await findDuplicatePhoto(
      scope,
      EVENT_ID,
      testSha256("original"),
    );

    expect(duplicate).toEqual({
      id: "photo-original",
      duplicateVariant: "original",
    });
  });

  it("matches a stored final hash and reports it as the final variant", async () => {
    await insertPhoto({
      id: "photo-final",
      eventId: EVENT_ID,
      sourceSha256: testSha256("raw"),
      finalSha256: testSha256("edited"),
    });

    const duplicate = await findDuplicatePhoto(
      scope,
      EVENT_ID,
      testSha256("edited"),
    );

    expect(duplicate).toEqual({
      id: "photo-final",
      duplicateVariant: "final",
    });
  });

  it("returns null for a hash this event has not seen", async () => {
    await insertPhoto({
      id: "photo-known",
      eventId: EVENT_ID,
      sourceSha256: testSha256("known"),
    });

    expect(
      await findDuplicatePhoto(scope, EVENT_ID, testSha256("unknown")),
    ).toBe(null);
  });

  it("does not match the same hash stored under a different event", async () => {
    await insertPhoto({
      id: "photo-elsewhere",
      eventId: OTHER_EVENT_ID,
      sourceSha256: testSha256("shared"),
    });

    expect(
      await findDuplicatePhoto(scope, EVENT_ID, testSha256("shared")),
    ).toBe(null);
  });

  it("ignores photos with no hash rather than treating NULL as a match", async () => {
    await insertPhoto({
      id: "photo-unhashed",
      eventId: EVENT_ID,
      sourceSha256: null,
    });

    expect(await findDuplicatePhoto(scope, EVENT_ID, testSha256("any"))).toBe(
      null,
    );
  });
});

describe("photos_event_source_sha256_idx", () => {
  /*
   * The UNIQUE partial index from migration 0007 is what makes duplicate
   * detection safe against two uploads racing past findDuplicatePhoto at once;
   * createPhoto catches the constraint failure and re-checks. Asserting it here
   * ties that recovery path to a real constraint rather than an assumed one.
   */
  it("rejects a second photo with the same source hash in one event", async () => {
    await insertPhoto({
      id: "photo-first",
      eventId: EVENT_ID,
      sourceSha256: testSha256("collide"),
    });

    await expect(
      insertPhoto({
        id: "photo-second",
        eventId: EVENT_ID,
        sourceSha256: testSha256("collide"),
      }),
    ).rejects.toThrow();
  });

  it("allows the same source hash under two different events", async () => {
    await insertPhoto({
      id: "photo-here",
      eventId: EVENT_ID,
      sourceSha256: testSha256("recurring"),
    });

    await expect(
      insertPhoto({
        id: "photo-there",
        eventId: OTHER_EVENT_ID,
        sourceSha256: testSha256("recurring"),
      }),
    ).resolves.toBeUndefined();
  });
});
