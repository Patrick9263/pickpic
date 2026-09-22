# Codex guidance for PickPic

Before making changes, read [CLAUDE.md](CLAUDE.md): **What this is**, **Commands**,
**Working sessions**, **Traps that cost real time**, **Conventions**, and the
**Architecture** sections relevant to your task. This file is an entrypoint, not a
replacement. Read the scheduled-review details only when working on that tooling.

Noncanonical orientation — see [What this is](CLAUDE.md#what-this-is) and
[Architecture](CLAUDE.md#architecture): PickPic is a private photo-proofing system.
**A heart is an edit request, not a social reaction.** Originals stay local, and
the iPad's durable on-device queue is authoritative for upload state. The React
frontend and one TypeScript Worker codebase serve three deployments sharing D1
and R2; the native Swift iPad app converts RAW files and uploads progressively.

## Instruction ownership

`CLAUDE.md` is the canonical source for assistant-neutral repository knowledge:
architecture, commands, testing, operational safeguards, implementation traps, and
conventions. `AGENTS.md` is Codex's discovery entrypoint and addendum; its shared-rule
summaries are noncanonical and link back to `CLAUDE.md`.

- Update shared guidance in `CLAUDE.md`, regardless of which assistant is working.
  If that makes an `AGENTS.md` summary or pointer inaccurate, update both files
  atomically in the same PR.
- Put Codex-only guidance in `AGENTS.md`. Keep Claude-only tooling, automation,
  permissions, and scheduled-job guidance in the Claude-specific portions of
  `CLAUDE.md`.
- Before committing either instruction file, check the other's pointers and
  summaries for needed changes. Synchronization is part of the current change;
  do not open a routine follow-up issue for it.
- Only create a synchronization issue when the companion update is genuinely
  blocked or intentionally deferred. Identify the exact rule, the canonical
  change, and the file or section still needing an update.

## Codex workflow

- Use a `codex/` branch in an isolated worktree based on freshly fetched
  `origin/main`. Inspect `git worktree list --porcelain`; reuse this task's managed
  worktree if present. Use Codex's managed-worktree tool when available and pass
  the returned directory explicitly to shell commands. Never nest a worktree or
  alter the shared checkout or another session's worktree, including locked Claude
  sessions. See the noncanonical safety summary below and the canonical
  [Working sessions](CLAUDE.md#working-sessions) rules.
- Stop at a reviewable PR unless Patrick explicitly authorizes further action;
  never infer permission to merge, deploy, or apply migrations from a development
  request. Check the staged paths and diff before committing, and report checks,
  caveats, branch, and commit with the PR.
- GitHub authentication is local setup: use `gh auth status`; if invalid, ask
  Patrick to run `gh auth login -h github.com`. Never store or print credentials
  to fix authentication. Do not copy `.claude/settings.local.json` permissions
  into repository configuration.
- Use `.nvmrc` through `nvm use` (install with `nvm install` if needed), then
  `npm ci`. Verify `node --version` and `npm --version` rather than relying on a
  machine-specific PATH. No project `.codex/config.toml` is needed for this setup.

## Commands and testing at a glance

Noncanonical summary of [Commands](CLAUDE.md#commands) and
[Working sessions](CLAUDE.md#working-sessions); read those sections for full
commands and caveats.

- **Correctness gate:** `npm run check` runs lint, `format:check`, all three Vitest
  suites, and the TypeScript/Vite build. Run it before pushing TypeScript or
  Prettier-scanned root-file changes, including these instructions, using Node 22.
- `npm run dev` serves current web/Worker edits; `wrangler dev` can serve stale
  build output. `npm run format:check` checks formatting; `npm run format` writes
  it. Run tools from your own worktree root: Prettier uses the repository
  `.gitignore`, including the nested `.claude/worktrees/` exclusion.
- `npm run test` separates pure Worker helpers (plain Node, `vitest.config.ts`),
  Worker/D1 integration tests (workerd, `vitest.config.workers.ts`), and frontend
  helpers/components (jsdom, `vitest.config.src.ts`). The Worker suite shares D1:
  keep file parallelism off and clear each file's tables in `beforeEach`. Preserve
  the frontend script's `NODE_OPTIONS=--no-experimental-webstorage`.
- Add tests for new pure logic in the same PR. `npm run test:e2e` is the local
  Playwright gallery smoke suite, outside `check` and CI; run it for gallery-flow
  changes. It seeds local D1 via migrations, so respect any task prohibition on
  migrations and report that validation limit. See the `AUTH_MODE=session`
  caveat in Commands before running it.
- Keep TypeScript (`worker/` + `src/`) and Swift (`ipad/`) sessions separate.
  For iPad changes, use the `xcodebuild ... clean build` command in Commands
  against `ipad/PickPic.xcodeproj`, scheme `PickPic`, with scratch derived data.
  A build does not run tests: run `xcodebuild test` and extend `PickPicTests` when
  touching pure logic or decoding. Filter large build logs while preserving the
  command's exit status. Never hand-edit the generated Swift Playgrounds
  `Package.swift` (see [iPad architecture](CLAUDE.md#ipad-app-ipadpickpicswiftpm)).

## Safety reminders before implementation

These are **noncanonical summaries**, not substitutes for the linked sections.

- [Working sessions](CLAUDE.md#working-sessions) and
  [Conventions](CLAUDE.md#conventions): one focused PR, no unrelated refactors.
  Preserve existing user changes and explanatory code comments. For source files
  around 1,200 lines or larger, use `rg` to find symbols and read relevant ranges;
  remeasure file sizes rather than reading whole large files.
- [Commands](CLAUDE.md#commands) and [CI/CD](CLAUDE.md#cicd): D1 migrations are
  manual and stay out of CI. A migration must be applied before
  its PR merges, from a checkout containing the new file. All three Workers share
  the database, and a push to `main` deploys all three. A green check is not
  authorization to run those operations.
- [Conventions](CLAUDE.md#conventions): the web app is dark-themed and every
  colour comes from the custom properties in `src/index.css`; never write a
  literal hex value into a new stylesheet, and do not copy colours out of the
  top half of `src/App.css`, which is overridden wholesale further down.
- [Conventions](CLAUDE.md#conventions): never commit secrets, credentials, local
  environment files, or Claude local settings. Runtime secrets live in Cloudflare.
  Preserve custom domains and admin Access protection. Security findings must
  stay out of the public tracker; see the private-reporting rule in
  [Scheduled review job](CLAUDE.md#scheduled-review-job), without adopting the
  unattended job's implementation workflow.
- [Traps 1–2](CLAUDE.md#traps-that-cost-real-time): new persisted `UploadJob`
  fields must decode with `decodeIfPresent(...) ?? default`; older
  `upload-queue.json` must still load or in-flight state is lost. An `UploadStage`
  change affects exhaustive switches **and** ad-hoc `stage ==` / `||` checks
  across files; search both shapes and prefer `isActiveOperation` for busy state.
- [Traps 3–4](CLAUDE.md#traps-that-cost-real-time): have Patrick fully quit Xcode
  before editing `project.pbxproj`. New Swift sources under `PickPic.swiftpm/`
  need all four project entries (build file, file reference, group child, Sources
  phase); confirm the build's `SwiftFileList`, since a green build can omit them.
- [Traps 5–6](CLAUDE.md#traps-that-cost-real-time): duplicate detection is
  server-authoritative via source hashes and the unique partial index on
  `(event_id, source_sha256)`. Preflight is only an optimization and must fall
  back to conversion on failure. `original_filename` is the RAW filename;
  `byte_size` is the proof JPEG size. Neither filename alone nor filename plus
  that byte size proves a RAW duplicate.
- [Trap 7](CLAUDE.md#traps-that-cost-real-time): missing GPS is normal. Use
  filename/capture time as reliable signals and retain public coordinate rounding.
