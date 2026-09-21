// Shared by the per-account storage panel and the operator console, so the two
// never disagree about what the same byte count is called.

// Decimal (1000-based), matching the iPad app's ByteCountFormatter(.file)
// output so the two faces show the same figure for the same bytes.
export function formatStorageSize(byteSize: number): string {
  if (byteSize < 1000) {
    return `${byteSize} B`;
  }

  if (byteSize < 1000 * 1000) {
    return `${Math.round(byteSize / 1000)} KB`;
  }

  if (byteSize < 1000 * 1000 * 1000) {
    return `${(byteSize / (1000 * 1000)).toFixed(1)} MB`;
  }

  return `${(byteSize / (1000 * 1000 * 1000)).toFixed(2)} GB`;
}

const PLAN_LABELS: Record<string, string> = {
  free: "Free",
  solo: "Solo",
  studio: "Studio",
};

// Falls through to the raw value rather than "Unknown": migration 0017 leaves
// accounts.plan without a CHECK precisely so a new tier can be added without a
// table rebuild, and a tier this build has not heard of should still be legible.
export function formatPlanLabel(plan: string): string {
  return PLAN_LABELS[plan] ?? plan;
}
