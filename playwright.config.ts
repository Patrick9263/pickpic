import { defineConfig, devices } from "@playwright/test";

const PORT = 5273;
const BASE_URL = `http://localhost:${PORT}`;

/*
 * Smoke-level coverage of the public gallery flow against a real `npm run
 * dev` -- see e2e/seed.ts for how fixtures get in and CLAUDE.md/#149's PR for
 * why. Local-only for now (see the PR description for the CI trade-off), so
 * this deliberately doesn't ride on `npm run check`.
 */
export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: "list",
  globalSetup: "./e2e/global-setup.ts",
  use: {
    baseURL: BASE_URL,
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "mobile",
      use: { ...devices["iPhone 13"] },
    },
  ],
  webServer: {
    command: `npm run dev -- --port ${PORT} --strictPort`,
    url: BASE_URL,
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
});
