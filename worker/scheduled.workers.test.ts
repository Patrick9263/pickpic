import {
  createExecutionContext,
  createScheduledController,
  env,
  waitOnExecutionContext,
} from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "./index.ts";
import { findUndeliveredTelegramNotifications } from "./telegram.ts";
import {
  clearTestData,
  deliverRawPhoto,
  insertEvent,
  insertPhoto,
  insertRawRequest,
  readRawPhotoState,
} from "./test-fixtures.ts";

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

function agoIso(milliseconds: number): string {
  return new Date(Date.now() - milliseconds).toISOString();
}

async function runCron(): Promise<void> {
  const ctx = createExecutionContext();

  await worker.scheduled(createScheduledController(), env, ctx);
  await waitOnExecutionContext(ctx);
}

beforeEach(async () => {
  await clearTestData();
});

describe("the cron's RAW reclaim sweep", () => {
  /*
   * The case the cron exists for: before it, the TTL only advanced when the
   * iPad polled this particular event, so a RAW in an event the photographer
   * had stopped opening stayed in R2 indefinitely.
   */
  it("reclaims an abandoned RAW in an event nothing is polling", async () => {
    await insertEvent({ id: "event-abandoned", shareToken: "share-abandoned" });
    await insertPhoto({ id: "photo-abandoned", eventId: "event-abandoned" });

    const storageKey = await deliverRawPhoto({
      photoId: "photo-abandoned",
      eventId: "event-abandoned",
    });

    /* Past RAW_DELIVERY_TTL_MAX_MS, so no account setting can keep it. */
    await insertRawRequest({
      photoId: "photo-abandoned",
      eventId: "event-abandoned",
      visitorToken: "visitor-abandoned____",
      fulfilledAt: agoIso(91 * DAY_MS),
    });

    await runCron();

    const state = await readRawPhotoState("photo-abandoned", storageKey);

    expect(state.objectExists).toBe(false);
    expect(state.rawStorageKey).toBeNull();
    expect(state.accountStorageBytes).toBe(0);
  });

  it("keeps a RAW its requester has not collected yet", async () => {
    await insertEvent({ id: "event-waiting", shareToken: "share-waiting" });
    await insertPhoto({ id: "photo-waiting", eventId: "event-waiting" });

    const storageKey = await deliverRawPhoto({
      photoId: "photo-waiting",
      eventId: "event-waiting",
    });

    await insertRawRequest({
      photoId: "photo-waiting",
      eventId: "event-waiting",
      visitorToken: "visitor-waiting______",
      fulfilledAt: agoIso(HOUR_MS),
    });

    await runCron();

    const state = await readRawPhotoState("photo-waiting", storageKey);

    expect(state.objectExists).toBe(true);
    expect(state.rawStorageKey).toBe(storageKey);
  });
});

describe("finding Telegram notifications the request path left unsent", () => {
  async function insertUploadStarted(seed: {
    eventId: string;
    status: "pending" | "sending" | "sent" | "failed";
    createdAt: string;
    updatedAt: string;
    attemptCount?: number;
  }): Promise<void> {
    await insertEvent({
      id: seed.eventId,
      shareToken: `share-${seed.eventId}`,
    });
    await env.DB.prepare(
      `
        INSERT INTO event_notifications (
          event_id,
          notification_type,
          status,
          attempt_count,
          last_attempt_at,
          created_at,
          updated_at
        )
        VALUES (?, 'telegram_upload_started', ?, ?, ?, ?, ?)
      `,
    )
      .bind(
        seed.eventId,
        seed.status,
        seed.attemptCount ?? 1,
        seed.updatedAt,
        seed.createdAt,
        seed.updatedAt,
      )
      .run();
  }

  async function markRawRequestNotification(seed: {
    photoId: string;
    status: "pending" | "sending" | "sent" | "failed";
    lastAttemptAt: string | null;
    attemptCount?: number;
  }): Promise<void> {
    await env.DB.prepare(
      `
        UPDATE raw_requests
        SET
          notification_status = ?,
          notification_last_attempt_at = ?,
          notification_attempt_count = ?
        WHERE photo_id = ?
      `,
    )
      .bind(
        seed.status,
        seed.lastAttemptAt,
        seed.attemptCount ?? 1,
        seed.photoId,
      )
      .run();
  }

  it("picks up failed and stranded upload-started rows only", async () => {
    await insertUploadStarted({
      eventId: "event-failed",
      status: "failed",
      createdAt: agoIso(HOUR_MS),
      updatedAt: agoIso(HOUR_MS),
    });

    /* An isolate that died mid-send: the lease ran out without a verdict. */
    await insertUploadStarted({
      eventId: "event-stranded",
      status: "sending",
      createdAt: agoIso(HOUR_MS),
      updatedAt: agoIso(HOUR_MS),
    });

    /* A request is sending this one right now. */
    await insertUploadStarted({
      eventId: "event-in-flight",
      status: "sending",
      createdAt: agoIso(60 * 1000),
      updatedAt: agoIso(60 * 1000),
    });

    await insertUploadStarted({
      eventId: "event-sent",
      status: "sent",
      createdAt: agoIso(HOUR_MS),
      updatedAt: agoIso(HOUR_MS),
    });

    await insertUploadStarted({
      eventId: "event-gave-up",
      status: "failed",
      createdAt: agoIso(HOUR_MS),
      updatedAt: agoIso(HOUR_MS),
      attemptCount: 5,
    });

    await insertUploadStarted({
      eventId: "event-stale-news",
      status: "failed",
      createdAt: agoIso(2 * DAY_MS),
      updatedAt: agoIso(2 * DAY_MS),
    });

    const undelivered = await findUndeliveredTelegramNotifications(env.DB);

    expect([...undelivered.uploadStartedEventIds].sort()).toEqual([
      "event-failed",
      "event-stranded",
    ]);
  });

  it("picks up an unsent RAW request unless it has since been fulfilled", async () => {
    await insertEvent({ id: "event-raw", shareToken: "share-raw" });

    for (const photoId of ["photo-failed", "photo-fulfilled", "photo-sent"]) {
      await insertPhoto({ id: photoId, eventId: "event-raw" });
    }

    await insertRawRequest({
      photoId: "photo-failed",
      eventId: "event-raw",
      visitorToken: "visitor-failed_______",
    });
    await markRawRequestNotification({
      photoId: "photo-failed",
      status: "failed",
      lastAttemptAt: agoIso(HOUR_MS),
    });

    /* The iPad already acted on it, so the photographer needs no ping. */
    await insertRawRequest({
      photoId: "photo-fulfilled",
      eventId: "event-raw",
      visitorToken: "visitor-fulfilled____",
      fulfilledAt: agoIso(30 * 60 * 1000),
    });
    await markRawRequestNotification({
      photoId: "photo-fulfilled",
      status: "failed",
      lastAttemptAt: agoIso(HOUR_MS),
    });

    await insertRawRequest({
      photoId: "photo-sent",
      eventId: "event-raw",
      visitorToken: "visitor-sent_________",
    });
    await markRawRequestNotification({
      photoId: "photo-sent",
      status: "sent",
      lastAttemptAt: agoIso(HOUR_MS),
    });

    const undelivered = await findUndeliveredTelegramNotifications(env.DB);

    expect(undelivered.rawRequests.map((row) => row.photoId)).toEqual([
      "photo-failed",
    ]);
  });
});
