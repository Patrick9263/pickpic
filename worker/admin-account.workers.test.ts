import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { BOOTSTRAP_ACCOUNT_ID } from "./accounts.ts";
import { clearTestData } from "./test-fixtures.ts";
import { adminRequest, expectError } from "./test-request.ts";

/*
 * #225: PUT /api/admin/account had no coverage at all before this -- name was
 * the only field it took, and it was never exercised through the route. Both
 * fields are now independently optional (a form can save just one), which is
 * exactly the kind of "looks obviously right" branching worth pinning down.
 */

const DAY_MS = 24 * 60 * 60 * 1000;

async function currentAccount(): Promise<{
  name: string;
  rawDeliveryTtlMs: number;
}> {
  const row = await env.DB.prepare(
    `SELECT name, raw_delivery_ttl_ms AS rawDeliveryTtlMs FROM accounts WHERE id = ?`,
  )
    .bind(BOOTSTRAP_ACCOUNT_ID)
    .first<{ name: string; rawDeliveryTtlMs: number }>();

  if (!row) {
    throw new Error("The bootstrap account is missing.");
  }

  return row;
}

/*
 * clearTestData resets storage_bytes but deliberately not name or
 * raw_delivery_ttl_ms (same reasoning as setAccountStorageCap's own comment),
 * and this file is the one place that actually PUTs both through the route --
 * so, unlike every read-only test elsewhere, the mutations here have to be
 * restored or they leak into whichever test file the shared D1 runs next.
 */
let restoreAccount: { name: string; rawDeliveryTtlMs: number };

beforeEach(async () => {
  await clearTestData();
  restoreAccount = await currentAccount();
});

afterEach(async () => {
  await env.DB.prepare(
    `UPDATE accounts SET name = ?, raw_delivery_ttl_ms = ? WHERE id = ?`,
  )
    .bind(
      restoreAccount.name,
      restoreAccount.rawDeliveryTtlMs,
      BOOTSTRAP_ACCOUNT_ID,
    )
    .run();
});

describe("PUT /api/admin/account", () => {
  it("rejects a rawDeliveryTtlMs below the minimum", async () => {
    const before = await currentAccount();

    const result = await adminRequest("PUT", "/api/admin/account", {
      json: { rawDeliveryTtlMs: DAY_MS },
    });

    expectError(
      result,
      400,
      "The RAW retention period must be between 2 and 90 days.",
    );
    expect((await currentAccount()).rawDeliveryTtlMs).toBe(
      before.rawDeliveryTtlMs,
    );
  });

  it("rejects a rawDeliveryTtlMs above the maximum", async () => {
    const result = await adminRequest("PUT", "/api/admin/account", {
      json: { rawDeliveryTtlMs: 91 * DAY_MS },
    });

    expectError(
      result,
      400,
      "The RAW retention period must be between 2 and 90 days.",
    );
  });

  it("rejects a non-integer rawDeliveryTtlMs", async () => {
    const result = await adminRequest("PUT", "/api/admin/account", {
      json: { rawDeliveryTtlMs: 5 * DAY_MS + 0.5 },
    });

    expectError(
      result,
      400,
      "The RAW retention period must be between 2 and 90 days.",
    );
  });

  it("saves a valid rawDeliveryTtlMs without requiring name", async () => {
    const before = await currentAccount();
    const nextTtlMs = 21 * DAY_MS;

    const result = await adminRequest<{
      account: { id: string; name: string; rawDeliveryTtlMs: number };
    }>("PUT", "/api/admin/account", {
      json: { rawDeliveryTtlMs: nextTtlMs },
    });

    expect(result.status).toBe(200);
    expect(result.body.account).toEqual({
      id: BOOTSTRAP_ACCOUNT_ID,
      name: before.name,
      rawDeliveryTtlMs: nextTtlMs,
    });
    expect((await currentAccount()).rawDeliveryTtlMs).toBe(nextTtlMs);
  });

  it("saves name alone without touching rawDeliveryTtlMs", async () => {
    const before = await currentAccount();

    const result = await adminRequest<{
      account: { id: string; name: string; rawDeliveryTtlMs: number };
    }>("PUT", "/api/admin/account", {
      json: { name: "Renamed Studio" },
    });

    expect(result.status).toBe(200);
    expect(result.body.account).toEqual({
      id: BOOTSTRAP_ACCOUNT_ID,
      name: "Renamed Studio",
      rawDeliveryTtlMs: before.rawDeliveryTtlMs,
    });
  });

  it("400s when neither field is present", async () => {
    const result = await adminRequest("PUT", "/api/admin/account", {
      json: {},
    });

    expectError(result, 400, "Nothing to update.");
  });
});
