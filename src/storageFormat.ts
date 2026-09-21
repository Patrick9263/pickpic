// Decimal (1000-based), matching the iPad app's ByteCountFormatter(.file)
// output so every face of PickPic shows the same figure for the same bytes.
//
// Extracted from StorageUsage.tsx when the operator console (#195) needed the
// same formatting for a cross-account list: two copies of this would have been
// two places for the iPad app's convention to drift away from.
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
