import type { AdminPrincipal } from "./access.ts";

/*
 * The bootstrap account created by migration 0013. Every pre-existing event and
 * photo was backfilled to it, so it owns all historical data.
 */
export const BOOTSTRAP_ACCOUNT_ID = "00000000-0000-4000-8000-000000000001";

export interface AccountRecord {
  id: string;
  name: string;
  status: string;

  /*
   * NULL means this account's rows live in the primary D1 database. See
   * resolveAccountDatabase.
   */
  databaseId: string | null;
}

/*
 * The single seam a shard split has to move through.
 *
 * D1 caps a database at 10 GB, which at roughly 2 KB of metadata per photo is a
 * few hundred photographers. Today every account lives in the primary database
 * so this returns env.DB -- but because every admin query already reaches its
 * handle through here, splitting a large account onto its own database becomes a
 * data move plus one row update rather than a rewrite of every query site.
 *
 * A non-null database_id with no binding to match it throws rather than falling
 * back to env.DB, because that fallback would silently read another tenant's
 * rows.
 */
export function resolveAccountDatabase(
  env: Env,
  account: AccountRecord,
): D1Database {
  if (account.databaseId !== null) {
    throw new Error(
      `Account ${account.id} is assigned to database ${account.databaseId}, which this worker has no binding for.`,
    );
  }

  return env.DB;
}

/*
 * Maps a verified Access principal to the account whose rows it may touch.
 *
 * Cloudflare Access currently admits exactly one operator plus the iPad service
 * token, and account_users is deliberately empty, so every verified principal
 * resolves to the bootstrap account. Adopting real user authentication replaces
 * the WHERE clause below with a join through account_users on
 * (auth_provider, auth_subject) -- which is exactly the shape of that table's
 * unique index -- and nothing else in the worker changes.
 *
 * This is a real SELECT rather than a hardcoded object so that having run the
 * migration is a hard precondition of serving admin traffic, and so database_id
 * is read from the row that owns it.
 */
export async function resolveAccountForPrincipal(
  database: D1Database,
  principal: AdminPrincipal,
): Promise<AccountRecord | null> {
  void principal;

  return database
    .prepare(
      `
        SELECT
          id,
          name,
          status,
          database_id AS databaseId
        FROM accounts
        WHERE id = ?
      `,
    )
    .bind(BOOTSTRAP_ACCOUNT_ID)
    .first<AccountRecord>();
}
