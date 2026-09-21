import type { OperatorAccountSummary } from "../types";

/*
 * Pulled out of OperatorPage.tsx for the same reason galleryHelpers.ts and
 * dashboardHelpers.ts exist: the counting and the "has this account ever done
 * anything" rule are the parts worth testing, and they do not need a render to
 * be exercised.
 */

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

/*
 * Past this, a relative figure stops being easier to read than the date it
 * stands for -- "94d ago" needs arithmetic, "2026-06-19" does not.
 */
const RELATIVE_CUTOFF_DAYS = 30;

export interface OperatorTotals {
  accountCount: number;
  userCount: number;

  /*
   * The split #195 asks for in as many words: how many beta testers there are
   * against how many have actually uploaded something. An account with events
   * but no photos counts as idle -- creating an event is the iPad app doing
   * its part, not the operator's photos arriving.
   */
  uploadingAccountCount: number;
  idleAccountCount: number;

  totalStorageBytes: number;
}

export function summariseOperatorAccounts(
  accounts: OperatorAccountSummary[],
): OperatorTotals {
  let userCount = 0;
  let uploadingAccountCount = 0;
  let totalStorageBytes = 0;

  for (const account of accounts) {
    userCount += account.users.length;
    totalStorageBytes += account.storageBytes;

    if (account.photoCount > 0) {
      uploadingAccountCount += 1;
    }
  }

  return {
    accountCount: accounts.length,
    userCount,
    uploadingAccountCount,
    idleAccountCount: accounts.length - uploadingAccountCount,
    totalStorageBytes,
  };
}

/*
 * `now` is a parameter rather than read from the clock so this is testable, and
 * so one render cannot show two rows measured against two different instants.
 */
export function formatLastUpload(
  lastPhotoUploadedAt: string | null,
  now: Date,
): string {
  if (lastPhotoUploadedAt === null) {
    return "Never";
  }

  const uploadedAt = new Date(lastPhotoUploadedAt);

  if (Number.isNaN(uploadedAt.getTime())) {
    return "Unknown";
  }

  const elapsedMs = now.getTime() - uploadedAt.getTime();

  /*
   * A timestamp in the future means clock skew somewhere, not a prediction.
   * Reporting it as "just now" is the least misleading thing available.
   */
  if (elapsedMs < HOUR_MS) {
    return "Just now";
  }

  if (elapsedMs < DAY_MS) {
    return `${Math.floor(elapsedMs / HOUR_MS)}h ago`;
  }

  const elapsedDays = Math.floor(elapsedMs / DAY_MS);

  if (elapsedDays < RELATIVE_CUTOFF_DAYS) {
    return `${elapsedDays}d ago`;
  }

  return uploadedAt.toISOString().slice(0, 10);
}
