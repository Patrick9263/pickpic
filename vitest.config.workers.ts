import path from "node:path";
import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

/*
 * Read here rather than in the setup file because the setup file runs inside
 * workerd, which has no filesystem. The migrations travel in as a binding.
 */
const migrations = await readD1Migrations(
  path.join(import.meta.dirname, "migrations"),
);

export default defineConfig({
  plugins: [
    cloudflareTest({
      /*
       * Real wrangler config, so these tests see the same bindings, compatibility
       * date and flags production does -- a schema or binding change that would
       * break the deployed worker breaks the suite too.
       */
      wrangler: { configPath: "./wrangler.jsonc" },

      miniflare: {
        bindings: { TEST_MIGRATIONS: migrations },
      },
    }),
  ],

  test: {
    include: ["worker/**/*.workers.test.ts"],
    setupFiles: ["./worker/test-setup.ts"],

    /*
     * One D1 database is shared by every test file, and this version of the pool
     * has no per-test storage isolation to stack on top of it. Each file clears
     * the tables it uses before each test, which is only safe if no other file is
     * running at the same time.
     */
    fileParallelism: false,
  },
});
