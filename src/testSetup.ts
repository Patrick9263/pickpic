import { afterEach } from "vitest";
import { cleanup } from "@testing-library/react";
import { stubMatchMedia } from "./testing/browserStubs";

/*
 * @testing-library/react only auto-registers this when it detects global
 * test hooks (vitest.config.ts's tests import `afterEach` explicitly rather
 * than relying on globals: true), so it's wired up by hand here.
 */
afterEach(() => {
  cleanup();
});

/*
 * jsdom doesn't implement window.matchMedia, and EventCard reads it
 * unconditionally on every mount (an unrelated max-width check), so any
 * test that renders a component tree containing it needs this stubbed
 * regardless of what the test itself exercises. Set here rather than in
 * each test file, so the next component test doesn't have to rediscover
 * that jsdom is missing it. A test that cares about the mobile branch can
 * still call stubMatchMedia(true) itself to override.
 */
stubMatchMedia();
