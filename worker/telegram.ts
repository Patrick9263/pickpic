type TelegramEnvironment = Env & {
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_CHAT_ID?: string;
};

interface TelegramEventRow {
  title: string;
  shareToken: string;
  notificationStatus: "pending" | "sending" | "sent" | "failed" | null;
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
  env: TelegramEnvironment,
  eventId: string,
  botToken: string,
  chatId: string,
): Promise<void> {
  try {
    const event = await env.DB.prepare(
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

    await env.DB.prepare(
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

    const claimResult = await env.DB.prepare(
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
        await env.DB.prepare(
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
    await env.DB.prepare(
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
  env: Env,
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

  ctx.waitUntil(notifyUploadStarted(telegramEnv, eventId, botToken, chatId));
}
