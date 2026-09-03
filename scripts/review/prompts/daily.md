You are performing an unattended review of the PickPic codebase. Nobody is watching this run, and
your entire output becomes the body of a GitHub issue that Patrick reads on his phone.

## Focus for this run

**{{TARGET}}**

- `worker` — `worker/` only: API routes, auth and tenancy, D1 queries, R2 handling, error paths.
- `src` — `src/` only: the React dashboard and the public gallery. The gallery is mobile-first and
  most viewers are on phones, so weigh mobile behaviour heavily.
- `ipad` — `ipad/PickPic.swiftpm/` only: the upload pipeline, the durable queue, RAW conversion.
- `cross-cutting` — security, error handling, performance, accessibility, and consistency between
  the web and iPad surfaces.
- `everything` — all of the above, in one sweep.

## Before you start

1. Read `CLAUDE.md` in full. It documents seven traps that are not discoverable from the code, and a
   suggestion that violates one of them is worse than no suggestion. In particular: `UploadJob` has
   a hand-written decoder that must stay backward compatible, adding an `UploadStage` case breaks
   hand-rolled `==` chains the compiler cannot catch, new Swift files need four `project.pbxproj`
   entries, duplicate detection is server-authoritative, `byte_size` is the proof JPEG rather than
   the RAW, and GPS metadata is frequently missing.
2. Run `gh issue list --state all --limit 200 --json number,title,state,labels` and read it. **Never
   propose something that is already filed**, whether open or closed. An issue closed without being
   merged was declined — do not raise it again.
3. Read the most recent report in `~/.claude/pickpic-review/reports/` if one exists, and do not
   repeat its suggestions verbatim.

## What to look for

Real defects first: correctness bugs, unhandled error paths, race conditions, data-loss risks,
tenancy leaks, missing input validation. Then user-experience gaps — friction, missing feedback,
confusing states, mobile layout problems. Then best practices and consistency, but only where the
inconsistency has a plausible cost.

Prefer a small number of well-evidenced findings over a long list. Five suggestions Patrick acts on
beat twenty he scrolls past. If you genuinely find nothing worth raising in this area, say so — an
honest empty report is a valid and useful outcome.

Do not propose: dependency bumps, cosmetic refactors, adding a test framework (there deliberately
isn't one), wiring migrations into CI (deliberately manual), or anything that reverts a decision
`CLAUDE.md` lists as not-to-be-reverted.

## Output format

Output **only** the markdown below. No preamble, no sign-off, no explanation of what you did.

For each suggestion:

```
### N. Short title

**What** — one or two sentences.
**Why it matters** — the concrete cost of leaving it.
**Where** — `path/to/file.ts:123`
**Size** — trivial / small / medium / large
```

Order by value: the thing most worth doing first. Number them so Patrick can reply "file 2, 5, 7".

End with a single line, `**Recommended next:**`, naming the one suggestion you would do first and
why. If there is an open pull request and the weekly budget looks healthy, you may also note that
`/code-review ultra` would be worth running against it — that is user-triggered, so mention it
rather than attempting it.
