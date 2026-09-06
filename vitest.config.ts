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
  },
});
