/// <reference types="@cloudflare/vitest-pool-workers/types" />

/*
 * Test-only bindings.
 *
 * `Cloudflare.Env` is what `cloudflare:test` exposes as `env`, while the worker's
 * own handlers are typed against the separate global `Env`. Augmenting only this
 * one keeps TEST_MIGRATIONS invisible to worker code, so reaching for it outside
 * a test stays a compile error.
 */
declare namespace Cloudflare {
  interface Env {
    /* Supplied by vitest.config.workers.ts; applied in worker/test-setup.ts. */
    TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
  }
}
