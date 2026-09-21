import type { OperatorAccountRecord } from "../types";

const DAY_MS = 24 * 60 * 60 * 1000;

export interface OperatorTotals {
  accountCount: number;
  userCount: number;
  eventCount: number;
  photoCount: number;
  storageBytes: number;

  /*
   * Accounts that exist but have never uploaded a photo. This is the number the
   * console exists to surface -- "signed up and never uploaded" is the one thing
   * a per-account dashboard structurally cannot show.
   */
  dormantCount: number;
}

export function summarizeOperatorAccounts(
  accounts: OperatorAccountRecord[],
): OperatorTotals {
  return accounts.reduce<OperatorTotals>(
    (running, account) => ({
      accountCount: running.accountCount + 1,
      userCount: running.userCount + account.users.length,
      eventCount: running.eventCount + account.eventCount,
      photoCount: running.photoCount + account.photoCount,
      storageBytes: running.storageBytes + account.storageBytes,
      dormantCount: running.dormantCount + (account.photoCount === 0 ? 1 : 0),
    }),
    {
      accountCount: 0,
      userCount: 0,
      eventCount: 0,
      photoCount: 0,
      storageBytes: 0,
      dormantCount: 0,
    },
  );
}

/*
 * Whole days rather than hours or minutes. Every question this console answers
 * is about weeks of beta activity, and "2 hours ago" invites reading a lagging
 * counter as if it were live.
 *
 * A future timestamp reads as "today" rather than negative: clock skew between
 * a device and the worker is not worth a second branch in the UI.
 */
export function formatDaysAgo(
  isoTimestamp: string | null,
  now: number,
): string {
  if (isoTimestamp === null) {
    return "never";
  }

  const parsed = Date.parse(isoTimestamp);

  if (Number.isNaN(parsed)) {
    return "unknown";
  }

  const days = Math.floor((now - parsed) / DAY_MS);

  if (days <= 0) {
    return "today";
  }

  if (days === 1) {
    return "yesterday";
  }

  return `${days} days ago`;
}
