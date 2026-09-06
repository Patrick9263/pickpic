import { applyD1Migrations, env } from "cloudflare:test";

/*
 * Every Workers-pool test runs against the real schema, applied from
 * migrations/ in the same order `wrangler d1 migrations apply` would use.
 * Nothing here maintains a second copy of the schema on purpose: a hand-written
 * CREATE TABLE that drifts from the migrations would make these tests agree with
 * themselves and disagree with production.
 */
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
