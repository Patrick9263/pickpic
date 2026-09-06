import { describe, expect, it } from "vitest";
import { createAccountScope } from "./tenancy.ts";
import type { AccountRecord } from "./accounts.ts";

const ACCOUNT: AccountRecord = {
  id: "11111111-1111-4111-8111-111111111111",
  name: "Test Studio",
  status: "active",
  plan: "solo",
  storageCapBytes: 1024,
  storageBytes: 0,
  databaseId: null,
};

const OTHER_ACCOUNT: AccountRecord = {
  ...ACCOUNT,
  id: "22222222-2222-4222-8222-222222222222",
};

interface RecordedStatement {
  sql: string;
  binds: unknown[];
}

/*
 * createAccountScope never executes a statement -- all it does is rewrite the
 * SQL and assemble the bind list -- so recording what it hands to prepare() and
 * bind() observes the whole of its behaviour without a D1 instance.
 */
function createRecordingDatabase(): {
  database: D1Database;
  statements: RecordedStatement[];
} {
  const statements: RecordedStatement[] = [];

  const database = {
    prepare(sql: string) {
      const statement: RecordedStatement = { sql, binds: [] };

      statements.push(statement);

      return {
        bind(...binds: unknown[]) {
          statement.binds = binds;

          return statement;
        },
      };
    },
  } as unknown as D1Database;

  return { database, statements };
}

describe("createAccountScope", () => {
  it("exposes the account and the unscoped handle it was built from", () => {
    const { database } = createRecordingDatabase();

    const scope = createAccountScope(ACCOUNT, database);

    expect(scope.account).toBe(ACCOUNT);
    expect(scope.database).toBe(database);
  });

  it("rewrites :accountId to a positional marker and binds the account id", () => {
    const { database, statements } = createRecordingDatabase();

    createAccountScope(ACCOUNT, database).prepare(
      "SELECT id FROM events WHERE account_id = :accountId",
    );

    expect(statements[0]).toEqual({
      sql: "SELECT id FROM events WHERE account_id = ?",
      binds: [ACCOUNT.id],
    });
  });

  it("interleaves the account id with the caller's binds in source order", () => {
    /*
     * D1 binds positionally, so the account id has to land in the slot the
     * marker occupied rather than at either end of the list -- getting this
     * backwards would bind an event id as the tenant.
     */
    const { database, statements } = createRecordingDatabase();

    createAccountScope(ACCOUNT, database).prepare(
      "SELECT id FROM events WHERE id = ? AND account_id = :accountId AND status = ?",
      "event-1",
      "ready",
    );

    expect(statements[0]?.binds).toEqual(["event-1", ACCOUNT.id, "ready"]);
  });

  it("repeats the account id for every occurrence of the marker", () => {
    const { database, statements } = createRecordingDatabase();

    createAccountScope(ACCOUNT, database).prepare(
      `
        UPDATE photos SET workflow_status = ?
        WHERE account_id = :accountId
          AND event_id IN (
            SELECT id FROM events WHERE account_id = :accountId AND id = ?
          )
      `,
      "final",
      "event-1",
    );

    expect(statements[0]?.binds).toEqual([
      "final",
      ACCOUNT.id,
      ACCOUNT.id,
      "event-1",
    ]);
    expect(statements[0]?.sql).not.toContain(":accountId");
  });

  it("throws rather than run a statement with no tenant constraint", () => {
    /*
     * The failure mode this guards is the expensive one: an unscoped WHERE on a
     * caller-supplied id returns another tenant's rows and looks entirely
     * normal doing it.
     */
    const { database } = createRecordingDatabase();

    expect(() =>
      createAccountScope(ACCOUNT, database).prepare(
        "SELECT id FROM events WHERE id = ?",
        "event-1",
      ),
    ).toThrow(/:accountId/);
  });

  it("throws when the bind count does not match the ? markers", () => {
    const { database } = createRecordingDatabase();

    const scope = createAccountScope(ACCOUNT, database);

    expect(() =>
      scope.prepare(
        "SELECT id FROM events WHERE account_id = :accountId AND id = ?",
        "event-1",
        "surplus",
      ),
    ).toThrow(/number of binds/);

    expect(() =>
      scope.prepare(
        "SELECT id FROM events WHERE account_id = :accountId AND id = ? AND status = ?",
        "event-1",
      ),
    ).toThrow(/number of binds/);
  });

  it("binds each scope's own account id", () => {
    const { database, statements } = createRecordingDatabase();

    const sql = "SELECT id FROM events WHERE account_id = :accountId";

    createAccountScope(ACCOUNT, database).prepare(sql);
    createAccountScope(OTHER_ACCOUNT, database).prepare(sql);

    expect(statements.map((statement) => statement.binds)).toEqual([
      [ACCOUNT.id],
      [OTHER_ACCOUNT.id],
    ]);
  });
});
