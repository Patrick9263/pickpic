import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { BOOTSTRAP_ACCOUNT_ID } from "./accounts.ts";
import {
  ORPHAN_GRACE_MS,
  scanStorageOrphans,
  type StorageOrphanScan,
} from "./operator.ts";
import { clearTestData, insertEvent, insertPhoto } from "./test-fixtures.ts";
import { adminRequest, expectError } from "./test-request.ts";

/*
 * #195. The point of the operator console is that it reads across accounts, so
 * the tests that matter are the ones with a second account in the database --
 * every other suite here only ever sees the bootstrap one.
 *
 * The harness drives localhost, which takes requireAdminAccess's
 * isLocalDevelopment branch and produces a principal of
 * ('cloudflare_access', 'local-development'). Granting operator here is
 * therefore inserting exactly that pair, which is also how the guard is meant
 * to be exercised against `npm run dev`.
 */

const LOCAL_PROVIDER = "cloudflare_access";
const LOCAL_SUBJECT = "local-development";

const SECOND_ACCOUNT_ID = "11111111-1111-4111-8111-111111111111";

interface OperatorUser {
  id: string;
  email: string | null;
  role: string;
  authProvider: string;
  createdAt: string;
  lastSeenAt: string | null;
}

interface OperatorAccount {
  id: string;
  name: string;
  status: string;
  plan: string;
  createdAt: string;
  databaseId: string | null;
  storageBytes: number;
  storageCapBytes: number;
  rawDeliveryTtlMs: number;
  eventCount: number;
  photoCount: number;
  lastEventAt: string | null;
  lastPhotoAt: string | null;
  users: OperatorUser[];
}

interface OperatorAccountsBody {
  accounts: OperatorAccount[];
  accountCount: number;
  truncated: boolean;
}

async function grantOperator(): Promise<void> {
  await env.DB.prepare(
    `
      INSERT INTO operators (id, auth_provider, auth_subject, note, created_at)
      VALUES (?, ?, ?, ?, ?)
    `,
  )
    .bind(
      crypto.randomUUID(),
      LOCAL_PROVIDER,
      LOCAL_SUBJECT,
      "test",
      new Date().toISOString(),
    )
    .run();
}

async function insertSecondAccount(): Promise<void> {
  const now = new Date().toISOString();

  await env.DB.prepare(
    `
      INSERT INTO accounts (id, name, status, database_id, created_at, updated_at)
      VALUES (?, ?, 'active', NULL, ?, ?)
    `,
  )
    .bind(SECOND_ACCOUNT_ID, "Second Studio", now, now)
    .run();
}

async function insertAccountUser(options: {
  id: string;
  accountId: string;
  email: string;
  authProvider?: string;
  role?: string;
}): Promise<void> {
  const now = new Date().toISOString();

  await env.DB.prepare(
    `
      INSERT INTO account_users (
        id,
        account_id,
        auth_provider,
        auth_subject,
        email,
        role,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `,
  )
    .bind(
      options.id,
      options.accountId,
      options.authProvider ?? "email",
      options.email,
      options.email,
      options.role ?? "owner",
      now,
      now,
    )
    .run();
}

/*
 * accounts and account_users outlive clearTestData on purpose -- the bootstrap
 * account is migration state, not fixture state -- so anything this file adds
 * to them has to come back out, or it leaks into whichever suite the shared D1
 * runs next. clearTestData comes first because events and photos hold
 * ON DELETE RESTRICT references to accounts, so a second account cannot be
 * removed while its rows are still there.
 */
async function resetOperatorFixtures(): Promise<void> {
  await clearTestData();

  await env.DB.batch([
    env.DB.prepare("DELETE FROM operators"),
    env.DB.prepare("DELETE FROM auth_sessions"),
    env.DB.prepare("DELETE FROM account_users"),
    env.DB.prepare("DELETE FROM accounts WHERE id <> ?").bind(
      BOOTSTRAP_ACCOUNT_ID,
    ),
  ]);
}

beforeEach(resetOperatorFixtures);

afterEach(resetOperatorFixtures);

describe("operator authorization", () => {
  it("refuses a caller with no operators row", async () => {
    const result = await adminRequest("GET", "/api/operator/accounts");

    expectError(result, 403, "Operator access is required.");
  });

  it("refuses a non-operator with 403 rather than 405, whatever the method", async () => {
    const result = await adminRequest("POST", "/api/operator/accounts");

    /*
     * Membership is checked before the method deliberately: answering 405 here
     * would tell a caller who is not an operator that the route exists and that
     * their identity was the only thing missing.
     */
    expectError(result, 403, "Operator access is required.");
  });

  it("refuses a state-changing request from a real operator", async () => {
    await grantOperator();

    const result = await adminRequest("POST", "/api/operator/accounts");

    expectError(result, 405, "The operator console is read-only.");
  });

  it("ignores an operators row for a different provider", async () => {
    await env.DB.prepare(
      `
        INSERT INTO operators (id, auth_provider, auth_subject, note, created_at)
        VALUES (?, 'email', ?, NULL, ?)
      `,
    )
      .bind(crypto.randomUUID(), LOCAL_SUBJECT, new Date().toISOString())
      .run();

    const result = await adminRequest("GET", "/api/operator/accounts");

    expectError(result, 403, "Operator access is required.");
  });

  it("404s an unknown operator route rather than falling through", async () => {
    await grantOperator();

    const result = await adminRequest("GET", "/api/operator/nope");

    expectError(result, 404, "API route not found.");
  });
});

describe("GET /api/operator/accounts", () => {
  beforeEach(async () => {
    await grantOperator();
  });

  it("lists every account, not just the caller's own", async () => {
    await insertSecondAccount();

    const result = await adminRequest<OperatorAccountsBody>(
      "GET",
      "/api/operator/accounts",
    );

    expect(result.status).toBe(200);
    expect(result.body.accountCount).toBe(2);
    expect(result.body.truncated).toBe(false);
    expect(result.body.accounts.map((account) => account.id).sort()).toEqual(
      [BOOTSTRAP_ACCOUNT_ID, SECOND_ACCOUNT_ID].sort(),
    );
  });

  it("counts events and photos per account rather than in total", async () => {
    await insertSecondAccount();

    await insertEvent({ id: "event-bootstrap", shareToken: "token-bootstrap" });
    await insertPhoto({ id: "photo-b1", eventId: "event-bootstrap" });
    await insertPhoto({ id: "photo-b2", eventId: "event-bootstrap" });

    await insertEvent({
      id: "event-second-a",
      shareToken: "token-second-a",
      accountId: SECOND_ACCOUNT_ID,
    });
    await insertEvent({
      id: "event-second-b",
      shareToken: "token-second-b",
      accountId: SECOND_ACCOUNT_ID,
    });
    await insertPhoto({
      id: "photo-s1",
      eventId: "event-second-a",
      accountId: SECOND_ACCOUNT_ID,
    });

    const result = await adminRequest<OperatorAccountsBody>(
      "GET",
      "/api/operator/accounts",
    );

    const byId = new Map(
      result.body.accounts.map((account) => [account.id, account]),
    );

    expect(byId.get(BOOTSTRAP_ACCOUNT_ID)).toMatchObject({
      eventCount: 1,
      photoCount: 2,
    });

    expect(byId.get(SECOND_ACCOUNT_ID)).toMatchObject({
      eventCount: 2,
      photoCount: 1,
    });
  });

  it("reports an account that signed up and never uploaded", async () => {
    await insertSecondAccount();

    const result = await adminRequest<OperatorAccountsBody>(
      "GET",
      "/api/operator/accounts",
    );

    const second = result.body.accounts.find(
      (account) => account.id === SECOND_ACCOUNT_ID,
    );

    expect(second).toMatchObject({
      eventCount: 0,
      photoCount: 0,
      lastEventAt: null,
      lastPhotoAt: null,
      users: [],
    });
  });

  it("groups users under the account they belong to", async () => {
    await insertSecondAccount();

    await insertAccountUser({
      id: "user-bootstrap",
      accountId: BOOTSTRAP_ACCOUNT_ID,
      email: "owner@example.com",
    });

    await insertAccountUser({
      id: "user-second",
      accountId: SECOND_ACCOUNT_ID,
      email: "second@example.com",
      role: "owner",
    });

    await insertAccountUser({
      id: "user-second-apple",
      accountId: SECOND_ACCOUNT_ID,
      email: "second-apple@example.com",
      authProvider: "apple",
    });

    const result = await adminRequest<OperatorAccountsBody>(
      "GET",
      "/api/operator/accounts",
    );

    const byId = new Map(
      result.body.accounts.map((account) => [account.id, account]),
    );

    expect(
      byId.get(BOOTSTRAP_ACCOUNT_ID)?.users.map((user) => user.email),
    ).toEqual(["owner@example.com"]);

    expect(
      byId
        .get(SECOND_ACCOUNT_ID)
        ?.users.map((user) => user.authProvider)
        .sort(),
    ).toEqual(["apple", "email"]);
  });

  it("reports the most recent session as lastSeenAt, ignoring revoked ones", async () => {
    await insertAccountUser({
      id: "user-bootstrap",
      accountId: BOOTSTRAP_ACCOUNT_ID,
      email: "owner@example.com",
    });

    const insertSession = (
      id: string,
      lastUsedAt: string,
      revokedAt: string | null,
    ) =>
      env.DB.prepare(
        `
          INSERT INTO auth_sessions (
            id,
            account_user_id,
            token_hash,
            created_at,
            expires_at,
            last_used_at,
            revoked_at,
            user_agent
          )
          VALUES (?, 'user-bootstrap', ?, ?, ?, ?, ?, NULL)
        `,
      )
        .bind(
          id,
          `hash-${id}`,
          "2026-01-01T00:00:00.000Z",
          "2099-01-01T00:00:00.000Z",
          lastUsedAt,
          revokedAt,
        )
        .run();

    await insertSession("session-old", "2026-02-01T00:00:00.000Z", null);
    await insertSession(
      "session-revoked",
      "2026-09-01T00:00:00.000Z",
      "2026-09-02T00:00:00.000Z",
    );

    const result = await adminRequest<OperatorAccountsBody>(
      "GET",
      "/api/operator/accounts",
    );

    const bootstrap = result.body.accounts.find(
      (account) => account.id === BOOTSTRAP_ACCOUNT_ID,
    );

    expect(bootstrap?.users[0]?.lastSeenAt).toBe("2026-02-01T00:00:00.000Z");
  });
});

/*
 * #249. R2 is shared across every suite in the run just as D1 is, so this block
 * empties events/ itself rather than trusting whatever an earlier file left.
 */
async function clearStoredObjects(): Promise<void> {
  let cursor: string | undefined;

  do {
    const listing = await env.pickpic_photos.list({
      prefix: "events/",
      cursor,
    });
    const keys = listing.objects.map((object) => object.key);

    if (keys.length > 0) {
      await env.pickpic_photos.delete(keys);
    }

    cursor = listing.truncated ? listing.cursor : undefined;
  } while (cursor);
}

async function putObject(key: string, size = 3): Promise<void> {
  await env.pickpic_photos.put(key, new Uint8Array(size));
}

const LIVE_EVENT_ID = "event-live";
const LIVE_PHOTO_ID = "photo-live";
const PROOF_KEY = `events/${LIVE_EVENT_ID}/photos/${LIVE_PHOTO_ID}.jpg`;
const FINAL_KEY = `events/${LIVE_EVENT_ID}/photos/${LIVE_PHOTO_ID}/finals/f.jpg`;
const RAW_KEY = `events/${LIVE_EVENT_ID}/photos/${LIVE_PHOTO_ID}/raw/r.raw`;
const VARIANT_KEY = `events/${LIVE_EVENT_ID}/photos/${LIVE_PHOTO_ID}/variants/original/u/thumbnail.jpg`;
const LIVE_ORPHAN_KEY = `events/${LIVE_EVENT_ID}/photos/${LIVE_PHOTO_ID}/variants/original/lost/preview.jpg`;
const DELETED_EVENT_ORPHAN_KEY = "events/event-gone/photos/p/preview.jpg";

/*
 * One photo whose every reference column is populated, each with a matching
 * object, plus an unreferenced object under that live event and one under an
 * event with no row at all.
 */
async function seedReconciliationFixture(): Promise<void> {
  await insertEvent({ id: LIVE_EVENT_ID, shareToken: "share-live" });
  await insertPhoto({ id: LIVE_PHOTO_ID, eventId: LIVE_EVENT_ID });

  await env.DB.batch([
    env.DB.prepare(
      `UPDATE photos SET final_storage_key = ?, raw_storage_key = ? WHERE id = ?`,
    ).bind(FINAL_KEY, RAW_KEY, LIVE_PHOTO_ID),
    env.DB.prepare(
      `
        INSERT INTO photo_variants (
          photo_id, source_kind, variant_kind, storage_key, content_type,
          byte_size, width, height, created_at
        )
        VALUES (?, 'original', 'thumbnail', ?, 'image/jpeg', 3, 1, 1, ?)
      `,
    ).bind(LIVE_PHOTO_ID, VARIANT_KEY, new Date().toISOString()),
  ]);

  for (const key of [PROOF_KEY, FINAL_KEY, RAW_KEY, VARIANT_KEY]) {
    await putObject(key);
  }

  await putObject(LIVE_ORPHAN_KEY, 5);
  await putObject(DELETED_EVENT_ORPHAN_KEY, 7);
}

describe("storage orphan reconciliation", () => {
  beforeEach(clearStoredObjects);

  afterEach(clearStoredObjects);

  it("reports only objects no row references, split by whether the event survives", async () => {
    await seedReconciliationFixture();

    const scan = await scanStorageOrphans(env);

    expect(scan.cursor).toBeNull();
    expect(scan.scannedObjects).toBe(6);
    expect(scan.scannedBytes).toBe(4 * 3 + 5 + 7);
    expect(scan.orphanCount).toBe(2);
    expect(scan.orphanBytes).toBe(12);
    expect(scan.missingEventOrphanCount).toBe(1);
    expect(scan.missingEventOrphanBytes).toBe(7);

    expect(
      scan.sample
        .map(({ key, eventExists }) => ({ key, eventExists }))
        .sort((a, b) => a.key.localeCompare(b.key)),
    ).toEqual(
      [
        { key: LIVE_ORPHAN_KEY, eventExists: true },
        { key: DELETED_EVENT_ORPHAN_KEY, eventExists: false },
      ].sort((a, b) => a.key.localeCompare(b.key)),
    );
  });

  it("counts an orphan as stale only once it is past the grace period", async () => {
    await seedReconciliationFixture();

    /*
     * A just-written orphan may be an upload whose INSERT has not landed, so it
     * must not read as stale -- that is the whole reason the split exists.
     */
    const fresh = await scanStorageOrphans(env);

    expect(fresh.staleOrphanCount).toBe(0);

    const later = await scanStorageOrphans(env, {
      now: Date.now() + ORPHAN_GRACE_MS + 60_000,
    });

    expect(later.staleOrphanCount).toBe(2);
    expect(later.staleOrphanBytes).toBe(12);
  });

  it("hands back a cursor when the bucket outruns one request, and resumes from it", async () => {
    await seedReconciliationFixture();

    /* One key per page, so five pages cover five of the six objects. */
    const first = await scanStorageOrphans(env, { listLimit: 1 });

    expect(first.scannedObjects).toBe(5);
    expect(first.cursor).not.toBeNull();

    const second = await scanStorageOrphans(env, {
      listLimit: 1,
      cursor: first.cursor ?? undefined,
    });

    expect(second.scannedObjects).toBe(1);
    expect(second.cursor).toBeNull();
    expect(first.orphanCount + second.orphanCount).toBe(2);
  });

  it("is operator-only over HTTP", async () => {
    const refused = await adminRequest("GET", "/api/operator/storage-orphans");

    expectError(refused, 403, "Operator access is required.");

    await grantOperator();
    await seedReconciliationFixture();

    const result = await adminRequest<StorageOrphanScan>(
      "GET",
      "/api/operator/storage-orphans",
    );

    expect(result.status).toBe(200);
    expect(result.body.orphanCount).toBe(2);
    expect(result.body.cursor).toBeNull();
  });
});
