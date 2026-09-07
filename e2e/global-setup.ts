import { execFileSync } from "node:child_process";

/*
 * The local D1 database backing `npm run dev` only has tables once
 * `migrations/` has been applied to it -- and unlike production, where
 * migrations are applied manually and deliberately kept out of CI (see
 * CLAUDE.md), a local, ephemeral D1 file under `.wrangler/state` is not
 * production data. Running this here means `npm run test:e2e` works on a
 * fresh checkout without a separate manual setup step, and it's safe to
 * re-run: an already-migrated database just reports nothing to do.
 */
export default function globalSetup(): void {
  execFileSync(
    "npx",
    ["wrangler", "d1", "migrations", "apply", "pickpic-db", "--local"],
    { stdio: "inherit" },
  );
}
