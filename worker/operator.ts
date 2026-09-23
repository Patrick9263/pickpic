import type { AdminPrincipal } from "./access.ts";
import { resolveAccountDatabase, type AccountRecord } from "./accounts.ts";
import { isStateChanging } from "./auth.ts";

/*
 * The cross-account view (#195).
 *
 * Everything in this file deliberately sees the *unscoped* database handle,
 * which is why it is a separate module behind a separate URL prefix rather than
 * another branch inside handleAdminRequest. An admin handler is typed against
 * AccountScope and TenantEnv precisely so that reaching for a cross-tenant
 * query is a compile error; teaching createAccountScope to drop its :accountId
 * requirement for an operator would have made every scoped query in the worker
 * cross-tenant-capable depending on who was asking, which is the one invariant
 * that makes tenancy here reviewable at all.
 *
 * So operator handlers never receive an AccountScope, and admin handlers can
 * never reach these queries. The separation is structural, not a convention.
 */

/*
 * A response listing every account on the deployment is not a thing to page
 * through on a phone, and it is not a thing to return unbounded either. The
 * count of accounts is reported separately so "how many beta testers are
 * there?" stays answerable even when the list itself is cut short.
 */
const MAX_OPERATOR_ACCOUNTS = 200;

interface OperatorAccountRow extends AccountRecord {
  createdAt: string;
}

interface OperatorUserRow {
  id: string;
  accountId: string;
  authProvider: string;
  email: string | null;
  role: string;
  createdAt: string;
  lastSeenAt: string | null;
}

interface AccountActivityRow {
  eventCount: number;
  photoCount: number;
  lastEventAt: string | null;
  lastPhotoAt: string | null;
}

function jsonResponse(data: unknown, status = 200): Response {
  return Response.json(data, {
    status,
    headers: {
      "Cache-Control": "no-store",
    },
  });
}

/*
 * Authorization on top of an already-verified principal, in the shape
 * requireOwnerRole established: a Response to send, or null to carry on.
 *
 * Membership is checked before the method, so a caller who is not an operator
 * gets the same 403 whatever it asked for. Checking the method first would have
 * answered a POST with 405 -- telling a non-operator that the route exists and
 * that their identity was the only thing missing.
 *
 * Read-only, with no "enter operator mode" step. A deliberate mode switch exists
 * to stop an operator making an accidental cross-account *write*; with nothing
 * writable there is nothing to stop, and refusing every non-GET outright is both
 * cheaper and stronger than a toggle. Adding actions later is one can_write
 * column, one route that stamps an expiry, and a relaxed check here -- it moves
 * no handlers.
 *
 * The lookup is on the principal's own (provider, subject) rather than on
 * anything the request carries, and that is what makes matching a row safe: no
 * route in this worker can write an arbitrary provider. Signup hardcodes 'email'
 * with the address it just proved by email, Apple linking hardcodes 'apple' with
 * Apple's stable sub, and 'cloudflare_access' can only ever come from an
 * Access-verified assertion, which has no account_users row at all. So an
 * operators row naming any of the three can only be matched by the person who
 * genuinely holds that identity.
 *
 * Note for local development: `npm run dev` on localhost takes the
 * isLocalDevelopment branch of requireAdminAccess, which hands every admin route
 * a principal of ('cloudflare_access', 'local-development'). That principal is
 * an operator only if a row says so, same as anywhere else, so exercising this
 * locally means inserting that pair into `operators` by hand.
 */
export async function requireOperatorPrincipal(
  request: Request,
  database: D1Database,
  principal: AdminPrincipal,
): Promise<Response | null> {
  const row = await database
    .prepare(
      `
        SELECT id
        FROM operators
        WHERE auth_provider = ?
          AND auth_subject = ?
      `,
    )
    .bind(principal.provider, principal.subject)
    .first<{ id: string }>();

  if (!row) {
    return jsonResponse({ error: "Operator access is required." }, 403);
  }

  if (isStateChanging(request)) {
    return jsonResponse({ error: "The operator console is read-only." }, 405);
  }

  return null;
}

/*
 * Returns null when nothing matched so routeRequest falls through to its generic
 * /api/ 404, matching how handleAdminRequest and handleAuthRequest behave.
 */
export async function handleOperatorRequest(
  request: Request,
  url: URL,
  env: Env,
): Promise<Response | null> {
  if (url.pathname === "/api/operator/accounts") {
    /*
     * Redundant today -- requireOperatorPrincipal has already refused every
     * non-GET -- and kept anyway, because it is the check that stays correct on
     * the day that guard relaxes for a writable route.
     */
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    return listOperatorAccounts(env);
  }

  if (url.pathname === "/api/operator/storage-orphans") {
    if (request.method !== "GET") {
      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    const cursor = url.searchParams.get("cursor") || undefined;

    return jsonResponse(await scanStorageOrphans(env, { cursor }));
  }

  return null;
}

async function listOperatorAccounts(env: Env): Promise<Response> {
  /*
   * accounts, account_users and auth_sessions are control-plane tables: they
   * describe who exists rather than what they uploaded, so they stay in the
   * primary database whatever happens to per-account photo data later. Reading
   * them together in one pass is therefore correct now and stays correct after a
   * shard split -- unlike the event and photo counts below.
   */
  const accountResult = await env.DB.prepare(
    `
      SELECT
        id,
        name,
        status,
        plan,
        storage_cap_bytes AS storageCapBytes,
        storage_bytes AS storageBytes,
        raw_delivery_ttl_ms AS rawDeliveryTtlMs,
        database_id AS databaseId,
        created_at AS createdAt
      FROM accounts
      ORDER BY created_at DESC, id
      LIMIT ?
    `,
  )
    .bind(MAX_OPERATOR_ACCOUNTS + 1)
    .all<OperatorAccountRow>();

  const truncated = accountResult.results.length > MAX_OPERATOR_ACCOUNTS;

  const accounts = truncated
    ? accountResult.results.slice(0, MAX_OPERATOR_ACCOUNTS)
    : accountResult.results;

  const totalRow = await env.DB.prepare(
    `SELECT COUNT(*) AS accountCount FROM accounts`,
  ).first<{ accountCount: number }>();

  /*
   * last_used_at comes from the live session rather than from a column on
   * account_users, so it answers "when was this person last here" without a
   * write on every request. It reads null once every session a user ever held
   * has expired and been swept (deleteExpiredSessions), which is the honest
   * answer for someone who has not signed in for over a month.
   */
  const userResult = await env.DB.prepare(
    `
      SELECT
        u.id AS id,
        u.account_id AS accountId,
        u.auth_provider AS authProvider,
        u.email AS email,
        u.role AS role,
        u.created_at AS createdAt,
        (
          SELECT MAX(s.last_used_at)
          FROM auth_sessions s
          WHERE s.account_user_id = u.id
            AND s.revoked_at IS NULL
        ) AS lastSeenAt
      FROM account_users u
      ORDER BY u.account_id, u.created_at
    `,
  ).all<OperatorUserRow>();

  const usersByAccount = new Map<string, OperatorUserRow[]>();

  for (const user of userResult.results) {
    const existing = usersByAccount.get(user.accountId);

    if (existing) {
      existing.push(user);
    } else {
      usersByAccount.set(user.accountId, [user]);
    }
  }

  const activityByAccount = await loadAccountActivity(env, accounts);

  return jsonResponse({
    accounts: accounts.map((account) => {
      const activity = activityByAccount.get(account.id);

      return {
        id: account.id,
        name: account.name,
        status: account.status,
        plan: account.plan,
        createdAt: account.createdAt,
        databaseId: account.databaseId,

        /*
         * The maintained counter, not a live SUM(). getStorageUsage reconciles
         * it against the true sum on every dashboard load, so it can lag for an
         * account nobody has opened recently -- which is a fair trade for a
         * cross-account view that costs one column read instead of a full
         * photo-table rollup per account.
         */
        storageBytes: account.storageBytes,
        storageCapBytes: account.storageCapBytes,
        rawDeliveryTtlMs: account.rawDeliveryTtlMs,

        eventCount: activity?.eventCount ?? 0,
        photoCount: activity?.photoCount ?? 0,
        lastEventAt: activity?.lastEventAt ?? null,
        lastPhotoAt: activity?.lastPhotoAt ?? null,

        users: (usersByAccount.get(account.id) ?? []).map((user) => ({
          id: user.id,
          email: user.email,
          role: user.role,
          authProvider: user.authProvider,
          createdAt: user.createdAt,
          lastSeenAt: user.lastSeenAt,
        })),
      };
    }),

    accountCount: totalRow?.accountCount ?? accounts.length,
    truncated,
  });
}

/*
 * Event and photo counts are the only per-account *data* read here, and they are
 * written as one statement per account rather than one cross-account JOIN on
 * purpose. Today every account resolves to env.DB and the statements all land in
 * a single batch, so the cost is one round trip either way -- but when an account
 * moves onto its own database the fan-out is then a second batch against a second
 * handle, rather than a query that has to be taken apart first.
 *
 * resolveAccountDatabase is left to throw for an account assigned to a database
 * this worker has no binding for, matching every other caller. A console that
 * quietly reported zero events for a sharded account would be worse than one
 * that says it cannot answer.
 */
async function loadAccountActivity(
  env: Env,
  accounts: OperatorAccountRow[],
): Promise<Map<string, AccountActivityRow>> {
  const groups = new Map<D1Database, OperatorAccountRow[]>();

  for (const account of accounts) {
    const database = resolveAccountDatabase(env, account);

    const existing = groups.get(database);

    if (existing) {
      existing.push(account);
    } else {
      groups.set(database, [account]);
    }
  }

  const activity = new Map<string, AccountActivityRow>();

  for (const [database, group] of groups) {
    const rows = await database.batch<AccountActivityRow>(
      group.map((account) =>
        database
          .prepare(
            `
              SELECT
                (SELECT COUNT(*) FROM events WHERE account_id = ?) AS eventCount,
                (SELECT COUNT(*) FROM photos WHERE account_id = ?) AS photoCount,
                (SELECT MAX(created_at) FROM events WHERE account_id = ?) AS lastEventAt,
                (SELECT MAX(created_at) FROM photos WHERE account_id = ?) AS lastPhotoAt
            `,
          )
          .bind(account.id, account.id, account.id, account.id),
      ),
    );

    group.forEach((account, index) => {
      const row = rows[index]?.results[0];

      if (row) {
        activity.set(account.id, row);
      }
    });
  }

  return activity;
}

/*
 * Read-only R2 reconciliation (#249): which objects under events/ does no
 * photos or photo_variants row point at?
 *
 * Every upload path writes to R2 before its D1 row lands, so a request
 * cancelled between the two -- or two variant uploads racing for one photo
 * where only one row survives -- leaves bytes that getStorageUsage can never
 * see, because it sums the database. This is the measurement that decides
 * whether a cleanup is worth building at all, so there is deliberately no
 * delete path here.
 *
 * The bucket is scanned a slice at a time: one request covers at most
 * ORPHAN_SCAN_MAX_PAGES list pages and hands back R2's cursor, and the console
 * loops until it comes back null. A single request walking the whole bucket
 * would put its subrequest count and CPU time at the mercy of how many objects
 * exist, which is exactly the number nobody knows yet.
 */
const ORPHAN_SCAN_MAX_PAGES = 5;

/*
 * An object younger than this may simply be an upload whose INSERT has not
 * landed yet, so it is reported apart from the ones that can only be orphans.
 * It is also the age gate a future cleanup would need, so reporting against it
 * now shows how much of the total that gate would leave behind.
 */
export const ORPHAN_GRACE_MS = 24 * 60 * 60 * 1000;

const ORPHAN_SAMPLE_LIMIT = 20;

/*
 * D1 caps a statement at 100 bound parameters and each lookup below binds one
 * per event id -- the same bound PREFLIGHT_CHUNK_SIZE works to in index.ts.
 */
const ORPHAN_EVENT_CHUNK_SIZE = 90;

const EVENT_KEY_PATTERN = /^events\/([^/]+)\//;

export interface StorageOrphanSample {
  key: string;
  size: number;
  uploaded: string;

  /*
   * False when the key names an event no database holds any more -- the
   * delete-time sweep's territory (#230) rather than a live-event race, and
   * worth telling apart before deciding what a cleanup should target.
   */
  eventExists: boolean;
}

export interface StorageOrphanScan {
  scannedObjects: number;
  scannedBytes: number;
  orphanCount: number;
  orphanBytes: number;

  /* Orphans older than ORPHAN_GRACE_MS -- the ones no in-flight upload explains. */
  staleOrphanCount: number;
  staleOrphanBytes: number;

  /* Orphans whose event row is gone entirely; a subset of orphanCount. */
  missingEventOrphanCount: number;
  missingEventOrphanBytes: number;

  sample: StorageOrphanSample[];

  /* R2's list cursor for the next slice; null once the bucket is exhausted. */
  cursor: string | null;
}

interface ReferencedKeys {
  liveEventIds: Set<string>;
  keys: Set<string>;
}

export async function scanStorageOrphans(
  env: Env,
  options: { cursor?: string; now?: number; listLimit?: number } = {},
): Promise<StorageOrphanScan> {
  const now = options.now ?? Date.now();
  const databases = await loadAllAccountDatabases(env);

  const scan: StorageOrphanScan = {
    scannedObjects: 0,
    scannedBytes: 0,
    orphanCount: 0,
    orphanBytes: 0,
    staleOrphanCount: 0,
    staleOrphanBytes: 0,
    missingEventOrphanCount: 0,
    missingEventOrphanBytes: 0,
    sample: [],
    cursor: null,
  };

  let cursor = options.cursor;

  for (let page = 0; page < ORPHAN_SCAN_MAX_PAGES; page += 1) {
    const listing = await env.pickpic_photos.list({
      prefix: "events/",
      cursor,
      limit: options.listLimit,
    });

    /*
     * Looked up per page rather than once for the whole bucket, so memory stays
     * bounded by one page of keys however large the data grows. An event whose
     * objects straddle two pages is simply queried twice.
     */
    const eventIds = new Set<string>();

    for (const object of listing.objects) {
      const eventId = EVENT_KEY_PATTERN.exec(object.key)?.[1];

      if (eventId !== undefined) {
        eventIds.add(eventId);
      }
    }

    const referenced = await loadReferencedKeys(databases, [...eventIds]);

    for (const object of listing.objects) {
      scan.scannedObjects += 1;
      scan.scannedBytes += object.size;

      if (referenced.keys.has(object.key)) {
        continue;
      }

      const eventId = EVENT_KEY_PATTERN.exec(object.key)?.[1];
      const eventExists =
        eventId !== undefined && referenced.liveEventIds.has(eventId);

      scan.orphanCount += 1;
      scan.orphanBytes += object.size;

      if (now - object.uploaded.getTime() >= ORPHAN_GRACE_MS) {
        scan.staleOrphanCount += 1;
        scan.staleOrphanBytes += object.size;
      }

      if (!eventExists) {
        scan.missingEventOrphanCount += 1;
        scan.missingEventOrphanBytes += object.size;
      }

      if (scan.sample.length < ORPHAN_SAMPLE_LIMIT) {
        scan.sample.push({
          key: object.key,
          size: object.size,
          uploaded: object.uploaded.toISOString(),
          eventExists,
        });
      }
    }

    cursor = listing.truncated ? listing.cursor : undefined;

    if (cursor === undefined) {
      break;
    }
  }

  scan.cursor = cursor ?? null;

  return scan;
}

/*
 * Every database any account resolves to. An R2 key carries an event id but
 * not an account id, so an object cannot be routed to the one database that
 * should hold its row; asking all of them is what stays correct after a shard
 * split. Today that is a single handle. As in loadAccountActivity, an account
 * assigned to a database this worker cannot reach throws rather than being
 * skipped -- a skipped shard would report every one of its objects as orphaned.
 */
async function loadAllAccountDatabases(env: Env): Promise<D1Database[]> {
  const result = await env.DB.prepare(
    `
      SELECT
        id,
        name,
        status,
        plan,
        storage_cap_bytes AS storageCapBytes,
        storage_bytes AS storageBytes,
        raw_delivery_ttl_ms AS rawDeliveryTtlMs,
        database_id AS databaseId
      FROM accounts
    `,
  ).all<AccountRecord>();

  const databases = new Set<D1Database>();

  for (const account of result.results) {
    databases.add(resolveAccountDatabase(env, account));
  }

  return [...databases];
}

/*
 * With photo_variants.storage_key, these are every column that can name an R2
 * object. A column added later has to be added here too, or every object it
 * names will read as orphaned -- loudly wrong rather than silently, which is
 * the safer direction for a report that comes before any delete path.
 */
const REFERENCE_COLUMNS = [
  "storage_key",
  "final_storage_key",
  "raw_storage_key",
] as const;

async function loadReferencedKeys(
  databases: D1Database[],
  eventIds: string[],
): Promise<ReferencedKeys> {
  const referenced: ReferencedKeys = {
    liveEventIds: new Set(),
    keys: new Set(),
  };

  for (
    let offset = 0;
    offset < eventIds.length;
    offset += ORPHAN_EVENT_CHUNK_SIZE
  ) {
    const chunk = eventIds.slice(offset, offset + ORPHAN_EVENT_CHUNK_SIZE);
    const placeholders = chunk.map(() => "?").join(", ");

    for (const database of databases) {
      const [events, photos, variants] = await database.batch<
        Record<string, string | null>
      >([
        database
          .prepare(`SELECT id FROM events WHERE id IN (${placeholders})`)
          .bind(...chunk),
        database
          .prepare(
            `
              SELECT storage_key, final_storage_key, raw_storage_key
              FROM photos
              WHERE event_id IN (${placeholders})
            `,
          )
          .bind(...chunk),
        database
          .prepare(
            `
              SELECT v.storage_key
              FROM photo_variants v
              JOIN photos p ON p.id = v.photo_id
              WHERE p.event_id IN (${placeholders})
            `,
          )
          .bind(...chunk),
      ]);

      for (const row of events.results) {
        if (row.id) {
          referenced.liveEventIds.add(row.id);
        }
      }

      for (const row of [...photos.results, ...variants.results]) {
        for (const column of REFERENCE_COLUMNS) {
          const key = row[column];

          if (key) {
            referenced.keys.add(key);
          }
        }
      }
    }
  }

  return referenced;
}
