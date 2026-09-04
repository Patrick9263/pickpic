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
npm run build:app         # same build with CLOUDFLARE_ENV=app
npm run deploy             # build + wrangler deploy (public worker)
npm run deploy:admin       # build:admin + wrangler deploy (admin worker)
npm run deploy:app         # build:app + wrangler deploy (app worker)
npm run cf-typegen         # regenerate worker-configuration.d.ts from wrangler.jsonc bindings
```

There is **no test suite**. `npm run check` is the only automated gate.

Use `npm run dev` when testing worker changes, not `npx wrangler dev` — the latter serves the last `npm run build` output from `dist/`, so edits appear to have no effect and stack traces point at `dist/pickpic/index.js`. `npm run dev` also reads `.dev.vars` (git-ignored; see `.dev.vars.example`), which is how `AUTH_MODE` and the magic-link sender are set locally.

Prettier 3 reads `.gitignore` (there is no `.prettierignore`), so anything ignored by the repo is also skipped by `format:check` — but it does **not** read a global gitignore. If `npm run check` starts failing on a local-only file that git seems to ignore, that's why: add the path to the repo's `.gitignore` rather than reformatting the file or "fixing" unrelated source.

The iPad app builds through **`ipad/PickPic.xcodeproj`** (scheme `PickPic`, one target), not through the `.swiftpm` package, even though the sources live under `ipad/PickPic.swiftpm/`. Patrick normally builds to a physical iPad from Xcode. To verify compilation from the CLI without code signing:

```bash
xcodebuild -project ipad/PickPic.xcodeproj -scheme PickPic -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/pickpic-build clean build
```

Use a scratch `-derivedDataPath` rather than wiping the shared DerivedData Xcode is using.

If `xcodebuild` ever reports that the active developer directory is `/Library/Developer/CommandLineTools`, `xcode-select` is pointed at the wrong place. Check with `xcode-select -p`; the fix needs sudo, so ask rather than working around it — `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` as a command prefix is a stopgap only.

Debug builds put the app's code in `PickPic.app/PickPic.debug.dylib`, not the `PickPic` stub binary. When checking whether a change actually made it into a build, run `strings` against the dylib.

Because sources are listed explicitly in `project.pbxproj` (see trap 3), a green build is not proof that a new file is actually compiled — it may just be absent. Confirm against the compile list:

```bash
cat /tmp/pickpic-build/Build/Intermediates.noindex/PickPic.build/Debug-iphonesimulator/PickPic.build/Objects-normal/arm64/PickPic.SwiftFileList
```

It should hold every `.swift` under `PickPic.swiftpm/` plus the generated `GeneratedAssetSymbols.swift`.

D1 migrations are **applied manually and deliberately stay out of CI.** Don't wire them into a workflow.

## Working sessions

Patrick usually drives this repo remotely, so sessions should stay cheap. Every turn resends the accumulated context, which makes a long mixed-topic session the expensive shape — not a long task.

- **One PR per session.** A merged, green PR is the point to start a fresh session rather than continuing. Say so out loud when you get there; Patrick shouldn't have to ask.
- **One surface per session** — `worker/` + `src/` (TypeScript) _or_ `ipad/` (Swift). Each pulls a different set of large files into context, so crossing between them mid-session roughly doubles what gets resent.
- **Never read these whole.** Grep for the symbol, then read the range around it:

  | File                                                      | Lines |
  | --------------------------------------------------------- | ----- |
  | `ipad/PickPic.swiftpm/Persistence/UploadQueueStore.swift` | 3,887 |
  | `worker/index.ts`                                         | 3,176 |
  | `ipad/PickPic.swiftpm/Views/UploadQueueView.swift`        | 1,577 |
  | `ipad/PickPic.swiftpm/Views/EventDetailView.swift`        | 1,368 |
  | `src/pages/DashboardPage.tsx`                             | 1,241 |

- **Filter `xcodebuild`.** A full build log is enormous and stays in context for the rest of the session. Append `2>&1 | grep -E "error:|warning:|BUILD" | tail -30`.
- **Device verification gets its own short session.** It produces no diff, so it shouldn't ride on the back of an implementation session already carrying a large context.
- **Keep prose short — replies, PR descriptions, commit bodies.** Everything written into a reply is resent on every later turn, so verbosity is charged repeatedly rather than once. Cut recaps of what the diff already shows, verification tables a sentence would cover, and "what's next" epilogues. A PR description should carry the _why_, the non-obvious trade-off, and anything surprising — not a tour of the feature.

  This is about reporting, not thinking, and it explicitly does not apply to code. **In-code comments explaining why stay exactly as they are** — they're the house style here and they're load-bearing. Keep design reasoning at the moment a decision is being made, and keep warnings before anything destructive.

- **Nothing is on the sandboxed `PATH`.** `node`, `npm`, and `gh` all resolve to "command not found" until you prepend their directories: `export PATH=/Users/patrick/.nvm/versions/node/v26.5.1/bin:/opt/homebrew/bin:$PATH`. Do it in the same call as the command; shell state does not persist between calls.

## Scheduled review job

Two LaunchAgents run [scripts/review/run-review.sh](scripts/review/run-review.sh) unattended, at
6:10am America/New_York — inside the hours Patrick is asleep, so an expensive run never competes
with his own interactive use.

| Agent                               | When           | What it does                                       |
| ----------------------------------- | -------------- | -------------------------------------------------- |
| `com.pickpic.claude-review-daily`   | Mon–Thu 6:10am | Rotating single-surface analysis                   |
| `com.pickpic.claude-review-surplus` | Fri–Sat 6:10am | Ready-issue implementation, else full-app analysis |

The daily pass rotates — Mon `worker/`, Tue `src/`, Wed `ipad/`, Thu cross-cutting — so each run
goes deep on one area rather than skimming everything and resurfacing yesterday's findings. Analysis
runs post a single GitHub issue labelled `review-report` with numbered suggestions; **they never
file individual issues**, because triage is Patrick's decision.

The surplus runs exist to spend a weekly budget window that would otherwise expire unused. If an
open issue carries the `ready` label, that run implements it and opens a PR; otherwise it runs a
**sweep** — several independent single-surface scans, then a consolidation pass that merges,
deduplicates and ranks them into one report of at most 12 entries. Only apply `ready` to work you
are comfortable being done unattended.

**A sweep fills the backlog toward a target, rather than running a fixed number of scans.** The
weekly window expires Sunday whether or not it was used, so an empty backlog with budget left is
exactly when it is worth stocking up. The target is 24 open untriaged issues under 45% weekly, 15
under 60%, and 9 above that; scans run at roughly three surviving findings each, so the count is
`(target − untriaged) / 3`. An empty backlog on a good week gets 8 scans; a full one gets 1.

Sweep targets are finer-grained than the weekday rotation's four (`worker-auth-and-tenancy`,
`src-gallery`, `ipad-pipeline`, `accessibility`, and so on — the full list is in
`scripts/review/prompts/daily.md`). That is deliberate: more scans only pay off if each covers
different ground, and rerunning `worker` five times mostly reproduces the first run's findings
however much budget is left.

The consolidation cap tracks the same deficit, so extra scans are not wasted — but the prompt says
explicitly not to pad, because a short honest report beats a padded one. The sweep also re-reads the
budget between scans and stops early at 70% weekly, since it is the longest thing this job does and
an interactive session can move that window underneath it.

**Budget gates.** The wrapper parses `claude -p "/usage"` before doing anything. It stands down
entirely above 80% weekly, and scales depth to headroom below that (Opus/`max` under 45%, Opus/`high`
to 65%, Sonnet/`medium` to 80%). Surplus runs additionally need weekly below 60%.

It will **defer across a session reset but never across a weekly one.** A session window is ≤5h and
resets the same morning, so sleeping through it still lands a useful report; crossing a weekly reset
would mean spending the _next_ week's budget early, which is the thing the job exists to avoid.

**Four rules the unattended implementation run must never break** — it never pushes to `main`,
merges, or deploys (a `main` push deploys all three workers); it never authors a D1 migration; it
does one issue per run; and it refuses to touch `project.pbxproj` while Xcode is running, because of
trap 4 below. It also stands down if more than 15 untriaged issues are already open, since a
suggestion generator that outruns triage capacity just creates work.

Every run appends one row to `~/.claude/pickpic-review/metrics.csv` — timestamp, mode, kind, target,
outcome, model, effort, scan count, findings, before/after budget for both windows, duration, and
the issue it posted. It is written from an `EXIT` trap, so **skips and failures are recorded as
faithfully as successes**: how often the job stands down and why is the more interesting trend than
what a successful run costs. Budget figures are integer percentages, so a single row is coarse, but
across weeks it answers whether sweeps are getting more expensive and how much of the weekly window
this job really consumes.

Logs are in `~/Library/Logs/claude-review-*.log` and `~/.claude/pickpic-review/logs/`; reports are
kept in `~/.claude/pickpic-review/reports/`. An unparseable `/usage` aborts the run and logs loudly
— **if reports stop arriving, read that log first**, because a silent parser break looks exactly
like "nothing worth reporting".

The versioned plists live in `scripts/review/launchd/`; the loaded copies are in
`~/Library/LaunchAgents/`. Edit the versioned ones, copy them across, then
`launchctl bootout` and `launchctl bootstrap gui/$(id -u) <plist>` to reload. To disable entirely:

```bash
launchctl bootout gui/$(id -u)/com.pickpic.claude-review-daily
launchctl bootout gui/$(id -u)/com.pickpic.claude-review-surplus
```

Dry-run the decision logic without spending anything: `./scripts/review/run-review.sh daily --dry-run`.

Two things about headless `claude -p` that cost a broken run to find, and that `--dry-run` cannot
catch because it exits before the invocation:

- **`--allowedTools` must be a bash array, not a string.** Rules like `Bash(git log:*)` contain a
  space, so an unquoted string expansion splits them into fragments and the CLI silently drops every
  one — logging `Ignoring --allowedTools rule "log:*)"` and then running with no Bash access at all.
- **`gh` cannot be granted to a headless run at all.** It requests approval regardless of the rule,
  even `Bash(gh:*)`, and in print mode nothing can approve it. Anything needing GitHub or network
  access must be done by the wrapper and passed in through the prompt — which is how the analysis
  run gets its deduplication list.

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

### One Worker codebase, three deployments

[worker/index.ts](worker/index.ts) is a single Cloudflare Worker deployed under three `wrangler.jsonc` targets sharing one D1 database (`pickpic-db`, binding `DB`) and one R2 bucket (`pickpic-photos`, binding `pickpic_photos`):

| Deployment  | Worker          | Domain                 | Auth              |
| ----------- | --------------- | ---------------------- | ----------------- |
| default env | `pickpic`       | `pickpic.photos`       | public            |
| `admin` env | `pickpic-admin` | `admin.pickpic.photos` | Cloudflare Access |
| `app` env   | `pickpic-app`   | `app.pickpic.photos`   | session cookie    |

All three run identical code. `/api/admin/*` is gated in `fetch` by `requireAdminPrincipal` ([worker/auth.ts](worker/auth.ts)), which dispatches on the `AUTH_MODE` var:

- `access` (the default when unset, and what both current deployments use) → `requireAdminAccess` ([worker/access.ts](worker/access.ts)), which verifies the `Cf-Access-Jwt-Assertion` header against Access's JWKS and is a deliberate no-op on localhost.
- `session` → one of our own `__Host-pickpic_session` cookies, for the coming `app.pickpic.photos`, which has no Access in front of it.

Anything else fails closed. It's a var rather than a hostname test because the same bundle serves every origin.

**The iPad app authenticates as a service token**, sending `CF-Access-Client-Id` / `CF-Access-Client-Secret` on every admin request (see `APIClient.makeAdminJSONRequest`); Access validates those at the edge and injects the JWT the worker checks. It never sees a cookie.

Access protection on the admin worker and the custom domains are load-bearing — don't casually change either.

`AdminPrincipal` is a discriminated union (`kind: "access" | "session"`), and `resolveAccountForPrincipal` switches on it: an Access principal resolves to the bootstrap account, a session principal to the account its `account_users` row names. Adding a third variant without handling it there is a compile error, which is the point.

Session cookies and magic-link tokens live in `auth_sessions` / `auth_login_tokens` (migration 0015); only SHA-256 hashes are stored. The `/api/auth/*` routes exist **only where `AUTH_MODE` is `session`** and 404 everywhere else, so the public gallery origin carries no email-sending endpoint and a magic link can only ever be built from the origin that will honour it.

Signing up is `POST /api/auth/signup` plus `/api/auth/signup/consume`, gated on a single shared `SIGNUP_INVITE_CODE` secret — unset means both answer 503, which is the intended state everywhere except `app.pickpic.photos`. Neither writes an `accounts` or `account_users` row: the intended email and studio name sit in `auth_signup_tokens` (migration 0016) until the emailed link is clicked, because `account_users` is unique on `(auth_provider, auth_subject)` and a row written before the address is proven would let anyone holding the code claim someone else's email permanently.

Because cookies are sent automatically where the Access header pair never was, every non-GET under `/api/admin/*` and `/api/auth/*` also requires a matching `Origin` header — testing those with `curl` needs `-H "Origin: <base>"` or it's a 403. **`/api/auth/apple/callback` is the single exemption**, and it is exempted by pathname in `handleAuthRequest` rather than by relaxing the rule: Apple returns the user with a genuine cross-site top-level POST that can never carry our own `Origin`. It is safe without that check because it draws no authority from a cookie — it verifies an Apple identity token pinned to our own client id, and a single-use `state` value it compares against the cookie set at `/api/auth/apple/start`.

Sign in with Apple (`/api/auth/apple/start` → `/api/auth/apple/callback`, [worker/apple.ts](worker/apple.ts)) **only ever authenticates an existing account, or attaches an Apple identity to one.** It must never create an account: signup is gated behind `SIGNUP_INVITE_CODE` precisely because an account is the one unauthenticated way to start consuming R2, and a provider nearly everyone already has would walk straight through that gate. Linking happens only when Apple supplies an address it has marked verified and an active account already owns that address, which adds a second `account_users` row (`auth_provider = 'apple'`, `auth_subject` = Apple's stable `sub`) against the same account. `account_users` needed no migration for this — 0013 left `auth_provider` free of a CHECK, and 0015's header comment already named `('apple', <Apple sub>)` as the intended second shape. Apple's `client_secret` is an ES256 JWT this worker signs per request from the `.p8` key; `APPLE_CLIENT_ID` and `APPLE_REDIRECT_URI` are vars, while `APPLE_TEAM_ID`, `APPLE_KEY_ID` and `APPLE_PRIVATE_KEY` are secrets. Apple rejects `http://` and `localhost` return URLs, so exercising this locally needs an HTTPS tunnel registered on the Services ID.

Routing inside `fetch` is manual: an ordered chain of `url.pathname` regex matches, each delegating to a dedicated async handler defined in the same 3000-line file. Add endpoints in that style; don't introduce a router library.

### One SPA, two faces

[src/App.tsx](src/App.tsx) is the only router — it reads `window.location.pathname` and renders `DashboardPage` (`/admin`), `GalleryPage` (`/g/:shareToken`), or the home page. The same bundle ships to both origins; which face a visitor sees depends on hostname and path, not a build flag. Cross-origin links use `VITE_ADMIN_APP_ORIGIN` / `VITE_PUBLIC_APP_ORIGIN` from `.env.production`.

**The gallery is mobile-first** — most viewers are on phones.

### Data model

- **Events** carry a share token and status: `draft → ready → completed → archived`.
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

[.github/workflows/check.yml](.github/workflows/check.yml): every PR and push to `main` runs `npm run check`. Pushes to `main` additionally deploy all three workers (`npm run deploy`, then `npm run deploy:admin`, then `npm run deploy:app`) using `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` secrets, with a `concurrency` group preventing overlapping production deploys.

## Conventions

- Keep changes PR-sized; avoid unrelated refactors. Inspect current `main` before proposing anything.
- **Never commit secrets** — Cloudflare Access service tokens, Telegram bot tokens or chat IDs, the `SIGNUP_INVITE_CODE`, the Apple `.p8` private key (`APPLE_PRIVATE_KEY`, downloadable from Apple exactly once), deployment credentials. Runtime secrets live in Cloudflare.
- Don't casually revert: the mobile Liked-filter lightbox behaviour, the large ZIP download fix, backward compatibility for older queue data, custom domains, or Access protection on the admin worker.
