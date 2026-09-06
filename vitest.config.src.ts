import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

/*
 * A separate config from vitest.config.ts (worker/*.test.ts, plain Node,
 * no DOM) rather than a shared one: src/ component tests need jsdom and
 * React's JSX transform, and folding that into the worker config would run
 * every worker test under jsdom too, or require per-file environment
 * overrides that are easy to get wrong silently.
 */
export default defineConfig({
  plugins: [react()],
  test: {
    include: ["src/**/*.test.{ts,tsx}"],
    environment: "jsdom",
    setupFiles: ["./src/testSetup.ts"],
  },
});
