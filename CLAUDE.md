# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

PickPic is a private photo-proofing system for event photography. The real workflow it serves: shoot an event on a Sony A7R V (`.ARW` RAW) → point the iPad app at the folder → it converts RAWs to proof JPEGs and uploads them progressively → a public gallery is published → viewers heart the photos they want edited → those RAWs get edited in Affinity Photo 2 on iPad and saved to an `Edited` folder → PickPic detects and uploads the finals.

**A heart is an edit request, not a social reaction.** That framing drives the whole data model.

Originals stay local. The cloud is never the source of truth for photos, and the iPad's durable on-device queue — not iPadOS background APIs — is the source of truth for upload state.

## Commands

Web app / Worker, from the repo root:

```bash
npm run dev             # vite dev server
npm run check           # lint + format:check + build — the correctness gate; CI runs exactly this
npm run lint             # oxlint (native binding; macOS-capable here)
npm run format           # prettier --write .
npm run build             # tsc -b && vite build
npm run build:admin       # same build with CLOUDFLARE_ENV=admin
npm run deploy             # build + wrangler deploy (public worker)
npm run deploy:admin       # build:admin + wrangler deploy (admin worker)
npm run cf-typegen         # regenerate worker-configuration.d.ts from wrangler.jsonc bindings
```

There is **no test suite**. `npm run check` is the only automated gate.

Prettier 3 reads `.gitignore` (there is no `.prettierignore`), so anything ignored by the repo is also skipped by `format:check` — but it does **not** read a global gitignore. If `npm run check` starts failing on a local-only file that git seems to ignore, that's why: add the path to the repo's `.gitignore` rather than reformatting the file or "fixing" unrelated source.

The iPad app builds through **`ipad/PickPic.xcodeproj`** (scheme `PickPic`, one target), not through the `.swiftpm` package, even though the sources live under `ipad/PickPic.swiftpm/`. Patrick normally builds to a physical iPad from Xcode. To verify compilation from the CLI without code signing:

```bash
xcodebuild -project ipad/PickPic.xcodeproj -scheme PickPic -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/pickpic-build clean build
```

Two gotchas. `xcode-select` on this machine may point at `/Library/Developer/CommandLineTools`, which makes `xcodebuild` fail outright; prefix the command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` to work around it without sudo. And use a scratch `-derivedDataPath` rather than wiping the shared DerivedData Xcode is using.

Because sources are listed explicitly in `project.pbxproj` (see trap 3), a green build is not proof that a new file is actually compiled — it may just be absent. Confirm against the compile list:

```bash
cat /tmp/pickpic-build/Build/Intermediates.noindex/PickPic.build/Debug-iphonesimulator/PickPic.build/Objects-normal/arm64/PickPic.SwiftFileList
```

It should hold every `.swift` under `PickPic.swiftpm/` plus the generated `GeneratedAssetSymbols.swift`.

D1 migrations are **applied manually and deliberately stay out of CI.** Don't wire them into a workflow.

## Traps that cost real time

These are not discoverable by reading the code, and several are silently destructive.

### 1. `UploadJob` has a hand-written `init(from:)` — this is the most destructive mistake available here

[UploadJob.swift:293+](ipad/PickPic.swiftpm/Models/UploadJob.swift) decodes the original fields with `decode(...)` and **every newer field with `decodeIfPresent(...) ?? default`**. Any field you add must follow that pattern. Getting it wrong makes existing `upload-queue.json` fail to decode, which destroys in-flight upload state on a user's device. Backward compatibility for older queue data is a hard requirement, not a nicety.

### 2. Adding an `UploadStage` case breaks far more than the compiler tells you

`UploadStage` (`queued → preparing → prepared → preflighting → converting → readyToUpload → uploading → completed/failed`) is switched exhaustively in ~7 places over `job.stage` across 6 files, plus 3 switches over `self` inside [UploadStage.swift](ipad/PickPic.swiftpm/Models/UploadStage.swift). Those the compiler catches.

What it **doesn't** catch: hand-rolled "is this job busy" tests written as `==` / `||` chains (concentrated in `UploadQueueStore.swift`, e.g. around lines 257, 314, 1266). They compile fine and are silently wrong for the new case. After any stage change, grep both shapes:

```bash
grep -rn "switch .*\.stage" --include="*.swift" ipad/PickPic.swiftpm/ && grep -rn "stage ==" --include="*.swift" ipad/PickPic.swiftpm/
```

Note `UploadStage.isActiveOperation` already encodes the busy/idle split — prefer it over adding another ad-hoc chain.

### 3. New Swift files need four `project.pbxproj` entries each

The `PBXFileSystemSynchronizedRootGroup` covers **only `ipad/PickPic/`** (assets, Info.plist). The ~49 Swift sources under `PickPic.swiftpm/` are referenced _explicitly_. Adding one file requires all four of:

1. a `PBXBuildFile` entry
2. a `PBXFileReference` entry
3. an entry in the owning `PBXGroup`'s `children`
4. an entry in the `PBXSourcesBuildPhase`

There is exactly one target (`PickPic`) and one Sources phase, so there's no ambiguity about which.

### 4. Xcode will not reload `project.pbxproj` edited on disk while it's open

Tell Patrick to **fully quit Xcode before you touch the project file.** Otherwise the build fails with "Cannot find X in scope" — or worse, Xcode writes the project from a stale in-memory copy and silently drops the new file references.

### 5. Duplicate detection is server-authoritative; preflight is only an optimization

The real check is `findDuplicatePhoto` in [worker/index.ts](worker/index.ts), enforced by `photos.source_sha256` with a **UNIQUE partial index on `(event_id, source_sha256)`** (`migrations/0007`); `final_sha256` has a non-unique index (`migrations/0008`).

The iPad-side preflight (`POST /api/admin/events/:id/photos/preflight`, added in PR #69) just returns stored hashes for RAW filenames the event already knows, so the iPad can hash only those files and skip converting confirmed duplicates. **Preflight must never block the pipeline** — any failure falls back to converting everything. Client chunks 500 filenames per request; the worker caps a request at 2000 (`MAX_PREFLIGHT_FILENAMES`) and internally batches SQL at 90 (`PREFLIGHT_CHUNK_SIZE`, a D1 bound-parameter limit).

### 6. `original_filename` is the RAW name; `byte_size` is the proof JPEG

`photos.original_filename` holds e.g. `DSC01015.ARW`, but `photos.byte_size` is the size of the _converted proof JPEG_, not the RAW. Filename-based lookups work against existing data; **filename + size lookups do not.**

Related: Sony resets frame counters between shoots, so the same filename genuinely recurs across different events' source files. Filename matching alone is never sufficient to call something a duplicate — that's exactly why preflight confirms with a hash.

### 7. GPS metadata is frequently missing

Nothing may depend on GPS being present. **Filename and capture time are the reliable signals.** Public gallery responses also deliberately round coordinates (`roundPublicCoordinate`).

## Architecture

### One Worker codebase, two deployments

[worker/index.ts](worker/index.ts) is a single Cloudflare Worker deployed under two `wrangler.jsonc` targets sharing one D1 database (`pickpic-db`, binding `DB`) and one R2 bucket (`pickpic-photos`, binding `pickpic_photos`):

| Deployment  | Worker          | Domain                 | Auth              |
| ----------- | --------------- | ---------------------- | ----------------- |
| default env | `pickpic`       | `pickpic.photos`       | public            |
| `admin` env | `pickpic-admin` | `admin.pickpic.photos` | Cloudflare Access |

Both run identical code. `/api/admin/*` is gated in `fetch` by `requireAdminAccess` ([worker/access.ts](worker/access.ts)), which verifies the `Cf-Access-Jwt-Assertion` header against Access's JWKS and is a deliberate no-op on localhost. **The iPad app authenticates as a service token**, sending `CF-Access-Client-Id` / `CF-Access-Client-Secret` on every admin request (see `APIClient.makeAdminJSONRequest`); Access validates those at the edge and injects the JWT the worker checks.

Access protection on the admin worker and the custom domains are load-bearing — don't casually change either.

Routing inside `fetch` is manual: an ordered chain of `url.pathname` regex matches, each delegating to a dedicated async handler defined in the same 3000-line file. Add endpoints in that style; don't introduce a router library.

### One SPA, two faces

[src/App.tsx](src/App.tsx) is the only router — it reads `window.location.pathname` and renders `DashboardPage` (`/admin`), `GalleryPage` (`/g/:shareToken`), or the home page. The same bundle ships to both origins; which face a visitor sees depends on hostname and path, not a build flag. Cross-origin links use `VITE_ADMIN_APP_ORIGIN` / `VITE_PUBLIC_APP_ORIGIN` from `.env.production`.

**The gallery is mobile-first** — most viewers are on phones.

### Data model

- **Events** carry a share token and status: `draft → uploading → ready → editing → completed → archived`.
- **Photos** belong to an event, carry `workflowStatus` (`idle → editing → final`), and dedupe by SHA-256 as above.
- **Variants**: thumbnail/preview JPEGs are generated client-side ([src/imageVariants.ts](src/imageVariants.ts), canvas-based) for both the `original` and `final` source of each photo, uploaded separately (`uploadPhotoVariants`), and stored in R2 beside the full-resolution image. The `original|final` × `thumbnail|preview` matrix in [src/types.ts](src/types.ts) is essential context before touching upload or image-serving code.
- **Hearts and comments** are scoped to a cookie/token visitor identity (no accounts) and only mutable through routes guarded by `requireOpenGallery`.
- **Telegram notifications** ([worker/telegram.ts](worker/telegram.ts)) queue in `event_notifications` with retry/backoff — best-effort side channel, not part of the request path.

### iPad app (`ipad/PickPic.swiftpm`)

SwiftUI, iOS 26 deployment target, **Swift 5 language mode with minimal concurrency checking** (`SWIFT_VERSION = 5.0`). Structure: `Models/`, `Services/` (RAW→JPEG conversion, hashing, duplicate preflight, folder bookmarks, background uploads), `Persistence/` (Keychain API config, on-disk upload queue, event-folder bookmarks), `Networking/` (`APIClient`, `PickPicEnvironment`), and `ViewModels`/`Views` per screen.

`UploadQueueStore` is `@MainActor` and is where the pipeline lives — ~3.8k lines, the single densest file in the project.

**Uploads are progressive**: never require the whole shoot to convert before anything uploads.

Transfers run through `BackgroundUploadSession` to survive suspension. For _recoverable_ failures the system background task is deliberately completed as **successful**, letting the internal queue represent unfinished work — this avoids a permanently stuck iPadOS activity indicator. That's an intentional tradeoff to revisit later in 2026, not a bug.

The app polls for newly-hearted photos and copies matching RAW files into a local `To Edit` folder through security-scoped bookmarks. Folder access must be re-validated (`FolderBookmarkService.canAccessFolder`) before every sync rather than assumed still valid.

`Package.swift` in the `.swiftpm` package is auto-generated by Swift Playgrounds — never hand-edit it.

### CI/CD

[.github/workflows/check.yml](.github/workflows/check.yml): every PR and push to `main` runs `npm run check`. Pushes to `main` additionally deploy both workers (`npm run deploy`, then `npm run deploy:admin`) using `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` secrets, with a `concurrency` group preventing overlapping production deploys.

## Conventions

- Keep changes PR-sized; avoid unrelated refactors. Inspect current `main` before proposing anything.
- **Never commit secrets** — Cloudflare Access service tokens, Telegram bot tokens or chat IDs, deployment credentials. Runtime secrets live in Cloudflare.
- Don't casually revert: the mobile Liked-filter lightbox behaviour, the large ZIP download fix, backward compatibility for older queue data, custom domains, or Access protection on the admin worker.
