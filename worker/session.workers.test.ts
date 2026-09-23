import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { BOOTSTRAP_ACCOUNT_ID } from "./accounts.ts";
import {
  createSession,
  hashAuthToken,
  resolveSession,
  revokeSession,
  touchSession,
} from "./session.ts";

/*
 * #194: the sliding rule itself is covered as a pure function in
 * session.test.ts. This pins the SQL half -- that resolveSession asks for the
 * extension and touchSession actually writes it, never backwards and never on
 * a revoked row -- against the real schema.
 */

const DAY = 24 * 60 * 60 * 1000;

const USER_ID = "session-test-user";

async function readRow(token: string): Promise<{
  expiresAt: string;
  lastUsedAt: string;
}> {
  const row = await env.DB.prepare(
    `
      SELECT expires_at AS expiresAt, last_used_at AS lastUsedAt
      FROM auth_sessions
      WHERE token_hash = ?
    `,
  )
    .bind(await hashAuthToken(token))
    .first<{ expiresAt: string; lastUsedAt: string }>();

  if (!row) {
    throw new Error("The session row is missing.");
  }

  return row;
}

/*
 * Backdates a session as if it had been created, and last extended, in the
 * past -- the only way to reach the sliding branch without a fake clock.
 */
async function backdate(
  token: string,
  createdAt: number,
  expiresAt: number,
  lastUsedAt: number,
): Promise<void> {
  await env.DB.prepare(
    `
      UPDATE auth_sessions
      SET created_at = ?, expires_at = ?, last_used_at = ?
      WHERE token_hash = ?
    `,
  )
    .bind(
      new Date(createdAt).toISOString(),
      new Date(expiresAt).toISOString(),
      new Date(lastUsedAt).toISOString(),
      await hashAuthToken(token),
    )
    .run();
}

/*
 * account_users is not cleared by clearTestData (see operator.workers.test.ts),
 * so this file removes exactly what it adds.
 */
beforeEach(async () => {
  const now = new Date().toISOString();

  await env.DB.batch([
    env.DB.prepare("DELETE FROM auth_sessions"),
    env.DB.prepare("DELETE FROM account_users WHERE id = ?").bind(USER_ID),
    env.DB.prepare(
      `
        INSERT INTO account_users (
          id, account_id, auth_provider, auth_subject, email, role,
          created_at, updated_at
        )
        VALUES (?, ?, 'email', ?, ?, 'owner', ?, ?)
      `,
    ).bind(
      USER_ID,
      BOOTSTRAP_ACCOUNT_ID,
      "session-test@example.com",
      "session-test@example.com",
      now,
      now,
    ),
  ]);
});

function request(): Request {
  return new Request("https://app.pickpic.photos/api/auth/session");
}

describe("sliding session expiry", () => {
  it("does not ask to extend a fresh session", async () => {
    const token = await createSession(env.DB, USER_ID, request());

    const session = await resolveSession(env.DB, token);

    expect(session?.extendedExpiresAt).toBe(null);
    expect(session?.needsTouch).toBe(false);
  });

  it("extends a session used after a day, and writes it", async () => {
    const token = await createSession(env.DB, USER_ID, request());

    const now = Date.now();

    await backdate(token, now - 10 * DAY, now + 20 * DAY, now - 10 * DAY);

    const session = await resolveSession(env.DB, token);

    expect(session?.needsTouch).toBe(true);
    expect(session?.extendedExpiresAt).not.toBe(null);

    await touchSession(
      env.DB,
      session!.principal.sessionId,
      session!.extendedExpiresAt,
    );

    const row = await readRow(token);

    expect(row.expiresAt).toBe(session!.extendedExpiresAt);
    expect(Date.parse(row.expiresAt)).toBeGreaterThanOrEqual(now + 29 * DAY);
  });

  it("keeps an expired session expired rather than reviving it", async () => {
    const token = await createSession(env.DB, USER_ID, request());

    const now = Date.now();

    await backdate(token, now - 40 * DAY, now - DAY, now - 31 * DAY);

    expect(await resolveSession(env.DB, token)).toBe(null);
  });

  it("stops at a year from creation", async () => {
    const token = await createSession(env.DB, USER_ID, request());

    const now = Date.now();

    await backdate(token, now - 364 * DAY, now + 2 * DAY, now - 2 * DAY);

    const session = await resolveSession(env.DB, token);

    expect(session?.extendedExpiresAt).toBe(null);
    expect(session?.expiresAt).toBe(new Date(now + 2 * DAY).toISOString());
  });

  it("never moves expires_at backwards", async () => {
    const token = await createSession(env.DB, USER_ID, request());

    const before = await readRow(token);

    await touchSession(
      env.DB,
      (await resolveSession(env.DB, token))!.principal.sessionId,
      new Date(Date.now() + DAY).toISOString(),
    );

    expect((await readRow(token)).expiresAt).toBe(before.expiresAt);
  });

  it("leaves expires_at alone when only last_used_at is due", async () => {
    const token = await createSession(env.DB, USER_ID, request());

    const before = await readRow(token);

    await touchSession(
      env.DB,
      (await resolveSession(env.DB, token))!.principal.sessionId,
      null,
    );

    expect((await readRow(token)).expiresAt).toBe(before.expiresAt);
  });

  it("does not extend a revoked session", async () => {
    const token = await createSession(env.DB, USER_ID, request());

    const now = Date.now();

    await backdate(token, now - 10 * DAY, now + 20 * DAY, now - 10 * DAY);

    const session = (await resolveSession(env.DB, token))!;

    await revokeSession(env.DB, session.principal.sessionId);

    await touchSession(
      env.DB,
      session.principal.sessionId,
      session.extendedExpiresAt,
    );

    expect((await readRow(token)).expiresAt).toBe(
      new Date(now + 20 * DAY).toISOString(),
    );
  });
});
