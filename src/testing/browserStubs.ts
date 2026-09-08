import { vi, type Mock } from "vitest";

export function userConfirms(): void {
  vi.spyOn(window, "confirm").mockReturnValue(true);
}

export function userCancels(): void {
  vi.spyOn(window, "confirm").mockReturnValue(false);
}

export function userPrompts(value: string | null): void {
  vi.spyOn(window, "prompt").mockReturnValue(value);
}

/*
 * jsdom doesn't implement the Clipboard API at all (no `navigator.clipboard`
 * property, not even a stub that throws), so this defines it rather than
 * spying on an existing one.
 */
export function stubClipboardWriteText(): Mock<
  (text: string) => Promise<void>
> {
  const writeText = vi
    .fn<(text: string) => Promise<void>>()
    .mockResolvedValue(undefined);

  Object.defineProperty(navigator, "clipboard", {
    value: { writeText },
    configurable: true,
    writable: true,
  });

  return writeText;
}

/*
 * jsdom doesn't implement window.matchMedia either. EventCard reads it (an
 * unrelated max-width check for its mobile photo-list collapse) on every
 * mount, so any test that renders an event needs this stubbed regardless of
 * what the test itself is exercising.
 */
export function stubMatchMedia(matches = false): void {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches,
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    })),
  });
}

/*
 * jsdom implements neither navigation (window.location.assign logs a "Not
 * implemented" error) nor a way to set the query string without one, and its
 * location cannot be spied on a property at a time. Swapping the whole object
 * is the only route in, which is why this hands back a restore function
 * instead of leaving it to vi.restoreAllMocks -- a defineProperty is not a
 * mock and restoreAllMocks will not undo it.
 */
export function stubLocation(search: string): {
  assign: Mock<(url: string) => void>;
  restore: () => void;
} {
  const original = Object.getOwnPropertyDescriptor(window, "location");
  const assign = vi.fn<(url: string) => void>();

  Object.defineProperty(window, "location", {
    configurable: true,
    writable: true,
    value: { assign, search },
  });

  return {
    assign,
    restore() {
      if (original) {
        Object.defineProperty(window, "location", original);
      }
    },
  };
}
