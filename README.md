# PickPic

PickPic is a private photo-proofing application for sharing event photos, collecting edit requests, discussing changes, and delivering final images.

The web application covers the photographer and viewer workflow. The native iPad app imports RAW camera files, converts them to proof JPEGs on device, and uploads them progressively in the background.

A heart is an edit request rather than a social reaction, so the whole workflow is built around viewers marking the photos they want edited.

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
- Move events through `draft`, `uploading`, `ready`, `editing`, `completed`, and `archived` states
- Archive and restore events, taking their public galleries offline and back
- Upload and replace full-resolution final JPEGs
- Compare original and final versions
- Clear edit requests and manage event photos
- Receive an optional Telegram notification when an upload starts

### iPad app

- Connect to the admin API with a Cloudflare Access service token
- Import `.ARW` RAW files from a folder and preview the conversion
- Convert RAW to proof JPEGs on device and upload progressively, without waiting for the whole shoot
- Skip re-uploading duplicates by confirming candidate filenames against stored hashes
- Keep a durable on-device upload queue that survives app suspension and relaunch
- Retry automatically when connectivity or configuration changes
- Review hearted photos and sync their RAW files into a local `To Edit` folder
- Detect finished edits in an `Edited` folder and upload them as finals
- Publish an event and share its public gallery link

### Viewer

- Open galleries through public share links
- View galleries by all photos, day, or approximate location
- Filter to liked photos or finished finals
- Heart a photo to request an edit or revision
- Leave optional comments and edit notes
- Edit or delete comments created by the same browser identity
- Switch between original and final versions
- Download the full image, falling back to the original when no final exists
- Select multiple photos and download them as a single ZIP
- Navigate with keyboard, touch, and swipe controls

Hearting and commenting are available while an event is `ready`. Archived events stop serving their gallery entirely.

## Architecture

```text
Public Worker
├── Landing page
├── Public galleries
├── Gallery API
└── Original, final, thumbnail, and preview images

Admin Worker
├── Photographer dashboard
├── Event, upload, and preflight APIs
├── Telegram upload notifications
└── Protected by Cloudflare Access

iPad app
├── RAW import, conversion, and durable upload queue
├── Liked-photo and finals sync
└── Authenticates with an Access service token

Shared Cloudflare resources
├── D1: events, photos, comments, hearts, metadata, variants, and notifications
└── R2: full images, final images, thumbnails, and previews
```

Both Workers run the same code from `worker/index.ts`, deployed twice against a shared D1 database and R2 bucket. ZIP archives are built in the viewer's browser rather than in the Worker, because the Worker CPU allowance is too small to checksum a large set of JPEGs.

## Development

```bash
npm run dev      # Vite dev server
npm run check    # Lint, format check, and build — what CI runs
npm run deploy   # Build and deploy the public Worker
```

The iPad app builds through `ipad/PickPic.xcodeproj`. D1 migrations in `migrations/` are applied manually.

See [CLAUDE.md](CLAUDE.md) for architecture details and the non-obvious pitfalls in this codebase.
