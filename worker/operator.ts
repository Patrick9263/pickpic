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
