You are implementing a single, already-triaged GitHub issue unattended. Nobody is watching this run.
Patrick reviews and merges everything himself, so your job ends at an open pull request.

## The issue

**#{{ISSUE}}** — read it first with `gh issue view {{ISSUE}}`.

## Hard rules

These exist because this run is unattended and some mistakes here are expensive to undo.

1. **Never push to `main`, never merge, never deploy.** Pushing to `main` triggers CI that deploys
   all three Cloudflare Workers to production. Work on a branch, open a PR, stop.
2. **Never author a D1 migration.** Migrations are applied manually and deliberately stay out of CI.
   If this issue needs a schema change, stop and report that instead — do not write the SQL.
3. **One issue only.** Do not opportunistically fix other things you notice. Note them in the PR
   body instead; unrelated changes make the diff unreviewable.
4. **If the issue is ambiguous, stop.** Report what is unclear rather than guessing. A wrong
   implementation costs Patrick more review time than an unstarted one.

## Before you start

Read `CLAUDE.md` in full. The seven traps it documents are not discoverable from the code, and
several are silently destructive. The Swift ones matter most here: `UploadJob`'s hand-written
`init(from:)` must decode every newer field with `decodeIfPresent(...) ?? default` or existing
upload queues fail to decode on real devices; adding an `UploadStage` case breaks hand-rolled `==`
chains the compiler will not flag; and a new Swift file needs four separate `project.pbxproj`
entries or it silently will not compile despite a green build.

Also honour the "Working sessions" guidance: never read the listed large files whole — grep for the
symbol and read the range around it.

## Steps

1. `git checkout main && git pull` then create a descriptively named branch.
2. Implement the change, matching the surrounding code's naming, idiom, and comment density. This
   repository keeps in-code comments explaining _why_ — that is house style and load-bearing, so
   write them where a decision is non-obvious.
3. Verify. For TypeScript, `npm run check` is the only gate and it must pass. For Swift, build with
   the scratch-derived-data `xcodebuild` command in `CLAUDE.md` and filter the output
   (`2>&1 | grep -E "error:|warning:|BUILD" | tail -30`) — an unfiltered build log is enormous. If
   you added a Swift file, confirm it appears in the compiled `SwiftFileList`.
4. Commit. End the message body with:

   ```
   Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
   ```

5. Push the branch and open a PR with `gh pr create --assignee @me`. Link the issue with
   `Closes #{{ISSUE}}`.

## The PR description

Keep it short. Patrick pays for every line of prose on every subsequent turn. Write the _why_, the
non-obvious trade-off, and anything surprising. Skip the feature tour, skip a verification table,
skip a "what's next" epilogue — the diff already shows what changed.

State plainly whether verification passed, and if something was skipped or could not be checked
unattended — device testing in particular — say so rather than implying it was covered.

## If you cannot finish

Do not open a half-done PR. Output a short explanation of what blocked you and leave the branch
unpushed.
