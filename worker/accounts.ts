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
   * Free-form label ("free" / "solo" / "studio" today) with no CHECK behind
   * it -- see migration 0017. storageCapBytes, not this, is what any cap
   * comparison should read; this is display-only.
   */
  plan: string;

  /*
   * The byte cap the storage panel measures usage against. Lives on the
   * account rather than being derived from `plan` so a single account (a
   * beta tester, a manual override) can carry a cap its plan name doesn't
   * imply, per migration 0017.
   */
  storageCapBytes: number;

  /*
   * The maintained running total an upload checks against storageCapBytes,
   * per migration 0018. Not authoritative on its own -- getStorageUsage
   * reconciles it against the true SUM() on every read, so this can lag
   * briefly but not drift indefinitely.
   */
  storageBytes: number;

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
 * Maps a verified principal to the account whose rows it may touch.
 *
 * A session principal already knows its account: resolving the session joined
 * account_users, so the answer came from that user's own row. There is no
 * fallback for this branch by design -- defaulting a session to the bootstrap
 * account would hand a stranger the operator's photos.
 *
 * An Access principal has no account_users row to join to. Cloudflare Access
 * admits exactly one operator plus the iPad service token, and their identifiers
 * are Cloudflare configuration that deliberately does not live in this
 * repository, so that branch still resolves to the bootstrap account. It stops
 * doing so when the iPad moves off service tokens (roadmap step 9).
 *
 * This is a real SELECT rather than a hardcoded object so that having run the
 * migration is a hard precondition of serving admin traffic, and so database_id
 * is read from the row that owns it.
 */
export async function resolveAccountForPrincipal(
  database: D1Database,
  principal: AdminPrincipal,
): Promise<AccountRecord | null> {
  const accountId =
    principal.kind === "session" ? principal.accountId : BOOTSTRAP_ACCOUNT_ID;

  return database
    .prepare(
      `
        SELECT
          id,
          name,
          status,
          plan,
          storage_cap_bytes AS storageCapBytes,
          storage_bytes AS storageBytes,
          database_id AS databaseId
        FROM accounts
        WHERE id = ?
      `,
    )
    .bind(accountId)
    .first<AccountRecord>();
}
