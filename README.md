# PickPic

PickPic is a private photo-proofing application for sharing event photos, collecting edit requests, discussing changes, and delivering final images.

The current web application focuses on the photographer and viewer workflow. A native iPad app is planned for importing RAW camera files, generating JPEGs locally, and uploading reliably in the background.

## Current features

### Photographer

- Create and continue photo events
- Batch-upload JPEG files
- Detect duplicate files using SHA-256 hashes
- Extract capture date and GPS metadata from EXIF
- Group and sort photos by capture date, location, and natural filename order
- Generate web-optimized thumbnails and previews in the browser
- Review hearted photos in an editing queue
- Move photos through `idle`, `editing`, and `final` workflow states
- Upload and replace full-resolution final JPEGs
- Compare original and final versions
- Clear edit requests and manage event photos

### Viewer

- Open galleries through public share links
- View galleries by all photos, day, or approximate location
- Heart a photo to request an edit or revision
- Leave optional comments and edit notes
- Edit or delete comments created by the same browser identity
- Switch between original and final versions
- Download the full final image
- Navigate with keyboard, touch, and swipe controls

## Architecture

```text
Public Worker
├── Landing page
├── Public galleries
├── Gallery API
└── Original, final, thumbnail, and preview images

Admin Worker
├── Photographer dashboard
├── Event and upload APIs
└── Protected by Cloudflare Access

Shared Cloudflare resources
├── D1: events, photos, comments, hearts, metadata, and variants
└── R2: full images, final images, thumbnails, and previews
```
