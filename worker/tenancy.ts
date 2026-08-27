import type { AccountRecord } from "./accounts.ts";

/*
 * Admin handlers are typed against this instead of Env, so reaching for env.DB
 * inside one is a compile error that `npm run check` catches rather than a
 * review miss. The only database handle an admin handler can see is the one
 * hanging off its AccountScope.
 */
export type TenantEnv = Omit<Env, "DB">;

const ACCOUNT_MARKER = ":accountId";

const PLACEHOLDER_PATTERN = /\?|:accountId\b/g;

export interface AccountScope {
  readonly account: AccountRecord;

  /*
   * For any statement whose WHERE is reached from a caller-supplied id.
   *
   * The SQL must contain :accountId at least once; the account id is bound into
   * those positions automatically, interleaved with the ordinary ? binds in
   * source order. Omitting the marker throws on the first request rather than
   * quietly returning another tenant's rows.
   */
  prepare(sql: string, ...binds: unknown[]): D1PreparedStatement;

  /*
   * The unscoped handle. Legal only for a statement already narrowed by an id
   * this request verified through findEventInAccount / findPhotoInAccount, and
   * for .batch(). Every use is a claim that the narrowing already happened --
   * `grep -n "scope.database" worker/index.ts` is the tenancy review checklist.
   */
  readonly database: D1Database;
}

export function createAccountScope(
  account: AccountRecord,
  database: D1Database,
): AccountScope {
  return {
    account,
    database,

    prepare(sql: string, ...binds: unknown[]): D1PreparedStatement {
      return database
        .prepare(sql.replace(PLACEHOLDER_PATTERN, "?"))
        .bind(...interleaveAccountBinds(sql, account.id, binds));
    },
  };
}

/*
 * Produces the bind list D1 expects: the account id wherever :accountId appeared
 * in the SQL, the caller's own arguments wherever ? appeared, in source order.
 *
 * A plain text scan is sufficient because no SQL literal in this worker contains
 * a '?' or the marker inside a string. If one ever does, this is where it breaks,
 * loudly.
 */
function interleaveAccountBinds(
  sql: string,
  accountId: string,
  binds: unknown[],
): unknown[] {
  const placeholders: string[] = sql.match(PLACEHOLDER_PATTERN) ?? [];

  if (!placeholders.includes(ACCOUNT_MARKER)) {
    throw new Error(
      "A scoped statement must constrain a tenant column with :accountId.",
    );
  }

  const bound: unknown[] = [];

  let nextBind = 0;

  for (const placeholder of placeholders) {
    bound.push(placeholder === ACCOUNT_MARKER ? accountId : binds[nextBind++]);
  }

  if (nextBind !== binds.length) {
    throw new Error(
      "A scoped statement was given a different number of binds than it has ? markers.",
    );
  }

  return bound;
}
