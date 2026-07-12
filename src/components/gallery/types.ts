import type { GalleryPhotoRecord } from "../../types";

export type PhotoVersion = "original" | "final";

export interface GalleryPhotoGroup {
  key: string;
  label: string;
  photos: GalleryPhotoRecord[];
  mapUrl: string | null;
}
