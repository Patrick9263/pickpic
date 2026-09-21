import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { BOOTSTRAP_ACCOUNT_ID } from "./accounts.ts";
import { listOperatorAccounts } from "./operator.ts";
import { clearTestData, insertEvent, insertPhoto } from "./test-fixtures.ts";
import { adminRequest, expectError } from "./test-request.ts";

/*
 * The route's guard and its query are tested separately on purpose.
 *
 * The guard is reachable through the route: this pool pins AUTH_MODE to
 * "access" and drives requests from localhost, so every request arrives as the
 * local-development principal, whose email is null and which therefore can
 * never be an operator. That is exactly the refusal worth pinning here.
 *
 * The success path is not reachable that way -- it would need a real session
 * cookie under AUTH_MODE=session -- so listOperatorAccounts is called directly
 * against the same D1 the route would hand it. That leaves the wiring between
 * the two (guard passes, then query runs) uncovered, which is four lines in
 * handleOperatorRequest.
 */

const SECOND_ACCOUNT_ID = "11111111-1111-4111-8111-111111111111";

/*
 * accounts and account_users survive clearTestData -- it deliberately keeps the
 * bootstrap account migration 0013 seeds -- so anything this file adds to them
 * has to be removed by this file or it leaks into whichever test runs next in
 * the shared database. Events and photos go first because accounts is
 * referenced ON DELETE RESTRICT.
 */
async function clearOperatorFixtures(): Promise<void> {
  await env.DB.prepare(`DELETE FROM account_users`).run();
  await env.DB.prepare(`DELETE FROM accounts WHERE id != ?`)
    .bind(BOOTSTRAP_ACCOUNT_ID)
    .run();
}

async function insertAccount(seed: {
  id: string;
  name: string;
  createdAt: string;
  storageBytes?: number;
}): Promise<void> {
  await env.DB.prepare(
    `
      INSERT INTO accounts (
        id,
        name,
        status,
        database_id,
        created_at,
        updated_at,
        storage_bytes
      )
      VALUES (?, ?, 'active', NULL, ?, ?, ?)
    `,
  )
    .bind(
      seed.id,
      seed.name,
      seed.createdAt,
      seed.createdAt,
      seed.storageBytes ?? 0,
    )
    .run();
}

async function insertAccountUser(seed: {
  id: string;
  accountId: string;
  email: string;
  role?: string;
  authProvider?: string;
  createdAt: string;
}): Promise<void> {
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
      seed.id,
      seed.accountId,
      seed.authProvider ?? "email",
      seed.email,
      seed.email,
      seed.role ?? "owner",
      seed.createdAt,
      seed.createdAt,
    )
    .run();
}

beforeEach(async () => {
  await clearTestData();
  await clearOperatorFixtures();
});

afterEach(async () => {
  await clearTestData();
  await clearOperatorFixtures();
});

describe("GET /api/admin/operator/accounts", () => {
  it("refuses a principal that is not an operator", async () => {
    const result = await adminRequest("GET", "/api/admin/operator/accounts");

    expectError(result, 403, "Operator access is required.");
  });

  it("refuses an unrecognised operator path the same way", async () => {
    const result = await adminRequest("GET", "/api/admin/operator/nothing");

    expectError(result, 403, "Operator access is required.");
  });
});

describe("listOperatorAccounts", () => {
  it("returns every account, newest first, with its users attached", async () => {
    await insertAccount({
      id: SECOND_ACCOUNT_ID,
      name: "Beta Tester",
      createdAt: "2026-09-01T00:00:00.000Z",
      storageBytes: 4096,
    });

    await insertAccountUser({
      id: "account-user-bootstrap",
      accountId: BOOTSTRAP_ACCOUNT_ID,
      email: "owner@example.com",
      createdAt: "2026-08-01T00:00:00.000Z",
    });

    await insertAccountUser({
      id: "account-user-beta",
      accountId: SECOND_ACCOUNT_ID,
      email: "beta@example.com",
      authProvider: "apple",
      createdAt: "2026-09-01T00:00:01.000Z",
    });

    const accounts = await listOperatorAccounts(env.DB);

    /*
     * The bootstrap account's created_at comes from migration 0013's
     * strftime('now'), so it is later than either fixture timestamp and sorts
     * first under created_at DESC.
     */
    expect(accounts.map((account) => account.id)).toEqual([
      BOOTSTRAP_ACCOUNT_ID,
      SECOND_ACCOUNT_ID,
    ]);

    const beta = accounts[1];

    expect(beta.name).toBe("Beta Tester");
    expect(beta.storageBytes).toBe(4096);
    expect(beta.users).toEqual([
      {
        id: "account-user-beta",
        email: "beta@example.com",
        role: "owner",
        authProvider: "apple",
        createdAt: "2026-09-01T00:00:01.000Z",
      },
    ]);
  });

  it("counts events and photos per account and dates the last upload", async () => {
    await insertEvent({ id: "event-1", shareToken: "share-token-operator-1" });

    await insertPhoto({
      id: "photo-1",
      eventId: "event-1",
      createdAt: "2026-09-10T00:00:00.000Z",
    });

    await insertPhoto({
      id: "photo-2",
      eventId: "event-1",
      createdAt: "2026-09-12T00:00:00.000Z",
    });

    const accounts = await listOperatorAccounts(env.DB);
    const bootstrap = accounts.find(
      (account) => account.id === BOOTSTRAP_ACCOUNT_ID,
    );

    expect(bootstrap?.eventCount).toBe(1);
    expect(bootstrap?.photoCount).toBe(2);
    expect(bootstrap?.lastPhotoUploadedAt).toBe("2026-09-12T00:00:00.000Z");
  });

  /*
   * The account that signed up and never uploaded is the case #195 exists to
   * surface, so it gets its own test rather than riding on the one above.
   */
  it("reports an account that has never uploaded as empty", async () => {
    await insertAccount({
      id: SECOND_ACCOUNT_ID,
      name: "Never Uploaded",
      createdAt: "2026-09-01T00:00:00.000Z",
    });

    const accounts = await listOperatorAccounts(env.DB);
    const idle = accounts.find((account) => account.id === SECOND_ACCOUNT_ID);

    expect(idle?.eventCount).toBe(0);
    expect(idle?.photoCount).toBe(0);
    expect(idle?.lastPhotoUploadedAt).toBeNull();
    expect(idle?.users).toEqual([]);
  });
});
