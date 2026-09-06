import { afterEach } from "vitest";
import { cleanup } from "@testing-library/react";

/*
 * @testing-library/react only auto-registers this when it detects global
 * test hooks (vitest.config.ts's tests import `afterEach` explicitly rather
 * than relying on globals: true), so it's wired up by hand here.
 */
afterEach(() => {
  cleanup();
});
