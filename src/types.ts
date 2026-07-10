export interface EventRecord {
  id: string;
  title: string;
  shareToken: string;
  status: string;
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
  viewerOwned: boolean;
}

export interface ViewerPhotoCommentRecord extends PhotoCommentRecord {
  viewerOwned: boolean;
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
  viewerHearted: boolean;
  comments: PhotoCommentRecord[];
}

export interface GalleryPhotoRecord extends Omit<PhotoRecord, "comments"> {
  comments: ViewerPhotoCommentRecord[];
  viewerHearted: boolean;
}
