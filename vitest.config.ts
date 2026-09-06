import { configDefaults, defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["worker/**/*.test.ts"],

    /*
     * The *.workers.test.ts files need D1 and the Workers runtime, so they run
     * under vitest.config.workers.ts instead. Spread the defaults back in
     * because setting `exclude` replaces them rather than adding to them.
     */
    exclude: [...configDefaults.exclude, "worker/**/*.workers.test.ts"],

    /*
     * Visibility only -- opt-in via `npm run test:coverage`, not wired into the
     * default `test`/`check` scripts and no threshold enforced. Scoped to
     * worker/** to match `include` above. Vitest already drops files matched by
     * `test.include` from the coverage report automatically, but this exclude
     * is kept explicit so it doesn't rely on that implicit behavior.
     */
    coverage: {
      provider: "v8",
      include: ["worker/**"],
      exclude: ["worker/**/*.test.ts"],
    },
  },
});
