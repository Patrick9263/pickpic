export type EventStatus =
  "draft" | "uploading" | "ready" | "editing" | "completed" | "archived";

export type GalleryStatus = "draft" | "ready" | "completed" | "archived";

export type PhotoWorkflowStatus = "idle" | "editing" | "final";

export interface EventRecord {
  id: string;
  title: string;
  shareToken: string;
  status: EventStatus;
  createdAt: string;
  updatedAt: string;
}

export interface PhotoCommentRecord {
  id: string;
  photoId: string;
  displayName: string;
  body: string;
  createdAt: string;
  updatedAt: string;
  resolvedAt: string | null;
}

export interface ViewerPhotoCommentRecord extends PhotoCommentRecord {
  viewerOwned: boolean;
}

export interface FinalPhotoRecord {
  originalFilename: string;
  contentType: string;
  byteSize: number;
  uploadedAt: string;
  imageUrl: string;
  variants: ImageVariantSet;
}

export interface PhotoRecord {
  id: string;
  eventId: string;
  originalFilename: string;
  contentType: string;
  byteSize: number;
  createdAt: string;
  imageUrl: string;
  heartCount: number;
  workflowStatus: PhotoWorkflowStatus;
  finalPhoto: FinalPhotoRecord | null;

  variants: ImageVariantSet;

  capturedAt: string | null;
  latitude: number | null;
  longitude: number | null;

  comments: PhotoCommentRecord[];
}

export interface GalleryPhotoRecord extends Omit<PhotoRecord, "comments"> {
  comments: ViewerPhotoCommentRecord[];
  viewerHearted: boolean;
}

export interface UploadBatchProgress {
  total: number;
  processed: number;
  uploaded: number;
  skipped: number;
  failed: number;
  warnings: number;
  currentFilename: string | null;
  currentStage: UploadStage | null;
}

export interface ImageVariantRecord {
  imageUrl: string;
  contentType: string;
  byteSize: number;
  width: number;
  height: number;
  createdAt: string;
}

export interface ImageVariantSet {
  thumbnail: ImageVariantRecord | null;
  preview: ImageVariantRecord | null;
}

export type UploadStage = "preparing" | "uploading" | "optimizing";

export type PhotoVariantSource = "original" | "final";
