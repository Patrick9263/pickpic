import type { TenantEnv } from "./tenancy.ts";

/*
 * Only the two secrets -- the database handle is passed separately so this
 * module works against whichever database owns the event, rather than always
 * reaching for the primary binding.
 */
type TelegramEnvironment = TenantEnv & {
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_CHAT_ID?: string;
};

interface TelegramEventRow {
  title: string;
  shareToken: string;
  notificationStatus: "pending" | "sending" | "sent" | "failed" | null;
  lastAttemptAt: string | null;
}

interface TelegramRawRequestRow {
  eventTitle: string;
  shareToken: string;
  originalFilename: string;
  displayName: string;
  notificationStatus: "pending" | "sending" | "sent" | "failed";
  lastAttemptAt: string | null;
}

interface TelegramAPIResponse {
  ok: boolean;
  description?: string;
}

const UPLOAD_STARTED_NOTIFICATION = "telegram_upload_started";
const NOTIFICATION_LEASE_MS = 5 * 60 * 1000;
const RETRY_DELAYS_MS = [0, 1000, 3000] as const;
const PUBLIC_GALLERY_BASE_URL = "https://pickpic.photos/g";

let didWarnAboutMissingConfiguration = false;
let didWarnAboutMissingConfigurationForRawRequests = false;

function wait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function getErrorMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim().length > 0) {
    return error.message.trim().slice(0, 500);
  }

  return "The Telegram notification could not be sent.";
}

async function sendTelegramMessage(
  botToken: string,
  chatId: string,
  text: string,
): Promise<void> {
  let response: Response;

  try {
    response = await fetch(
      `https://api.telegram.org/bot${botToken}/sendMessage`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          chat_id: chatId,
          text,
          link_preview_options: {
            is_disabled: true,
          },
        }),
      },
    );
  } catch {
    throw new Error("The Telegram request could not be completed.");
  }

  let result: TelegramAPIResponse | null = null;

  try {
    result = (await response.json()) as TelegramAPIResponse;
  } catch {
    // Telegram can occasionally return a non-JSON gateway response.
  }

  if (!response.ok || !result?.ok) {
    throw new Error(
      result?.description ?? `Telegram returned HTTP ${response.status}.`,
    );
  }
}

async function notifyUploadStarted(
  database: D1Database,
  eventId: string,
  botToken: string,
  chatId: string,
): Promise<void> {
  try {
    const event = await database
      .prepare(
        `
        SELECT
          e.title,
          e.share_token AS shareToken,
          n.status AS notificationStatus,
          n.last_attempt_at AS lastAttemptAt
        FROM events e
        LEFT JOIN event_notifications n
          ON n.event_id = e.id
          AND n.notification_type = ?
        WHERE e.id = ?
      `,
      )
      .bind(UPLOAD_STARTED_NOTIFICATION, eventId)
      .first<TelegramEventRow>();

    if (!event) {
      return;
    }

    const now = new Date().toISOString();
    const staleBefore = new Date(
      Date.now() - NOTIFICATION_LEASE_MS,
    ).toISOString();

    if (event.notificationStatus === "sent") {
      return;
    }

    if (
      event.notificationStatus === "sending" &&
      event.lastAttemptAt !== null &&
      event.lastAttemptAt >= staleBefore
    ) {
      return;
    }

    await database
      .prepare(
        `
        INSERT INTO event_notifications (
          event_id,
          notification_type,
          status,
          attempt_count,
          created_at,
          updated_at
        )
        VALUES (?, ?, 'pending', 0, ?, ?)
        ON CONFLICT(event_id, notification_type)
        DO NOTHING
      `,
      )
      .bind(eventId, UPLOAD_STARTED_NOTIFICATION, now, now)
      .run();

    const claimResult = await database
      .prepare(
        `
        UPDATE event_notifications
        SET
          status = 'sending',
          attempt_count = attempt_count + 1,
          last_attempt_at = ?,
          last_error = NULL,
          updated_at = ?
        WHERE
          event_id = ?
          AND notification_type = ?
          AND (
            status IN ('pending', 'failed')
            OR (
              status = 'sending'
              AND (
                last_attempt_at IS NULL
                OR last_attempt_at < ?
              )
            )
          )
      `,
      )
      .bind(now, now, eventId, UPLOAD_STARTED_NOTIFICATION, staleBefore)
      .run();

    if (claimResult.meta.changes !== 1) {
      return;
    }

    const galleryUrl =
      `${PUBLIC_GALLERY_BASE_URL}/` + encodeURIComponent(event.shareToken);
    const message = [
      "📷 PickPic upload started",
      "",
      event.title,
      galleryUrl,
    ].join("\n");

    let lastError = "The Telegram notification could not be sent.";

    for (const retryDelay of RETRY_DELAYS_MS) {
      if (retryDelay > 0) {
        await wait(retryDelay);
      }

      try {
        await sendTelegramMessage(botToken, chatId, message);

        const sentAt = new Date().toISOString();
        await database
          .prepare(
            `
            UPDATE event_notifications
            SET
              status = 'sent',
              sent_at = ?,
              last_error = NULL,
              updated_at = ?
            WHERE
              event_id = ?
              AND notification_type = ?
              AND status = 'sending'
          `,
          )
          .bind(sentAt, sentAt, eventId, UPLOAD_STARTED_NOTIFICATION)
          .run();

        return;
      } catch (error) {
        lastError = getErrorMessage(error);
      }
    }

    const failedAt = new Date().toISOString();
    await database
      .prepare(
        `
        UPDATE event_notifications
        SET
          status = 'failed',
          last_error = ?,
          updated_at = ?
        WHERE
          event_id = ?
          AND notification_type = ?
          AND status = 'sending'
      `,
      )
      .bind(lastError, failedAt, eventId, UPLOAD_STARTED_NOTIFICATION)
      .run();

    console.error("Telegram upload-start notification failed:", lastError);
  } catch (error) {
    console.error(
      "Unable to process Telegram upload-start notification:",
      getErrorMessage(error),
    );
  }
}

export function scheduleUploadStartedNotification(
  database: D1Database,
  env: TenantEnv,
  ctx: ExecutionContext,
  eventId: string,
): void {
  const telegramEnv = env as TelegramEnvironment;
  const botToken = telegramEnv.TELEGRAM_BOT_TOKEN?.trim();
  const chatId = telegramEnv.TELEGRAM_CHAT_ID?.trim();

  if (!botToken || !chatId) {
    if (!didWarnAboutMissingConfiguration) {
      console.warn("Telegram upload-start notification is not configured.");
      didWarnAboutMissingConfiguration = true;
    }

    return;
  }

  ctx.waitUntil(notifyUploadStarted(database, eventId, botToken, chatId));
}

/*
 * Unlike upload-start, this lease/retry state lives directly on the
 * raw_requests row (migration 0019) rather than in event_notifications --
 * that table's PRIMARY KEY (event_id, notification_type) is a one-row-per-event
 * singleton and can't represent many independent RAW requests per event. The
 * (photo_id, visitor_id) row created by addRawRequest already exists by the
 * time this runs, so there is no bootstrap INSERT step here.
 */
async function notifyRawRequested(
  database: D1Database,
  photoId: string,
  visitorId: string,
  botToken: string,
  chatId: string,
): Promise<void> {
  try {
    const rawRequest = await database
      .prepare(
        `
        SELECT
          e.title AS eventTitle,
          e.share_token AS shareToken,
          p.original_filename AS originalFilename,
          v.display_name AS displayName,
          r.notification_status AS notificationStatus,
          r.notification_last_attempt_at AS lastAttemptAt
        FROM raw_requests r
        INNER JOIN photos p
          ON p.id = r.photo_id
        INNER JOIN events e
          ON e.id = p.event_id
        INNER JOIN gallery_visitors v
          ON v.id = r.visitor_id
        WHERE
          r.photo_id = ?
          AND r.visitor_id = ?
      `,
      )
      .bind(photoId, visitorId)
      .first<TelegramRawRequestRow>();

    if (!rawRequest) {
      return;
    }

    const now = new Date().toISOString();
    const staleBefore = new Date(
      Date.now() - NOTIFICATION_LEASE_MS,
    ).toISOString();

    if (rawRequest.notificationStatus === "sent") {
      return;
    }

    if (
      rawRequest.notificationStatus === "sending" &&
      rawRequest.lastAttemptAt !== null &&
      rawRequest.lastAttemptAt >= staleBefore
    ) {
      return;
    }

    const claimResult = await database
      .prepare(
        `
        UPDATE raw_requests
        SET
          notification_status = 'sending',
          notification_attempt_count = notification_attempt_count + 1,
          notification_last_attempt_at = ?,
          notification_last_error = NULL
        WHERE
          photo_id = ?
          AND visitor_id = ?
          AND (
            notification_status IN ('pending', 'failed')
            OR (
              notification_status = 'sending'
              AND (
                notification_last_attempt_at IS NULL
                OR notification_last_attempt_at < ?
              )
            )
          )
      `,
      )
      .bind(now, photoId, visitorId, staleBefore)
      .run();

    if (claimResult.meta.changes !== 1) {
      return;
    }

    const galleryUrl =
      `${PUBLIC_GALLERY_BASE_URL}/` + encodeURIComponent(rawRequest.shareToken);
    const message = [
      "📥 RAW file requested",
      "",
      `${rawRequest.eventTitle} — ${rawRequest.originalFilename}`,
      `Requested by ${rawRequest.displayName}`,
      galleryUrl,
    ].join("\n");

    let lastError = "The Telegram notification could not be sent.";

    for (const retryDelay of RETRY_DELAYS_MS) {
      if (retryDelay > 0) {
        await wait(retryDelay);
      }

      try {
        await sendTelegramMessage(botToken, chatId, message);

        const sentAt = new Date().toISOString();
        await database
          .prepare(
            `
            UPDATE raw_requests
            SET
              notification_status = 'sent',
              notification_sent_at = ?,
              notification_last_error = NULL
            WHERE
              photo_id = ?
              AND visitor_id = ?
              AND notification_status = 'sending'
          `,
          )
          .bind(sentAt, photoId, visitorId)
          .run();

        return;
      } catch (error) {
        lastError = getErrorMessage(error);
      }
    }

    await database
      .prepare(
        `
        UPDATE raw_requests
        SET
          notification_status = 'failed',
          notification_last_error = ?
        WHERE
          photo_id = ?
          AND visitor_id = ?
          AND notification_status = 'sending'
      `,
      )
      .bind(lastError, photoId, visitorId)
      .run();

    console.error("Telegram RAW-request notification failed:", lastError);
  } catch (error) {
    console.error(
      "Unable to process Telegram RAW-request notification:",
      getErrorMessage(error),
    );
  }
}

export function scheduleRawRequestNotification(
  database: D1Database,
  env: TenantEnv,
  ctx: ExecutionContext,
  photoId: string,
  visitorId: string,
): void {
  const telegramEnv = env as TelegramEnvironment;
  const botToken = telegramEnv.TELEGRAM_BOT_TOKEN?.trim();
  const chatId = telegramEnv.TELEGRAM_CHAT_ID?.trim();

  if (!botToken || !chatId) {
    if (!didWarnAboutMissingConfigurationForRawRequests) {
      console.warn("Telegram RAW-request notification is not configured.");
      didWarnAboutMissingConfigurationForRawRequests = true;
    }

    /*
     * Mark the row as "not configured" by writing an explanatory message to
     * notification_last_error. This distinguishes it from "not yet sent"
     * (where notification_last_error is NULL), allowing operators to diagnose
     * configuration issues without shell access to the database.
     */
    ctx.waitUntil(
      database
        .prepare(
          `
          UPDATE raw_requests
          SET
            notification_last_error = ?
          WHERE
            photo_id = ?
            AND visitor_id = ?
            AND notification_last_error IS NULL
        `,
        )
        .bind(
          "Telegram bot token and/or chat ID not configured",
          photoId,
          visitorId,
        )
        .run(),
    );

    return;
  }

  ctx.waitUntil(
    notifyRawRequested(database, photoId, visitorId, botToken, chatId),
  );
}
