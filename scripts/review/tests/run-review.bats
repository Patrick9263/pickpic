# Bats coverage for the deterministic decision logic in ../run-review.sh: the depth ladder
# (decide_depth), the budget gates around it, and the surplus mode's backlog-driven sweep sizing
# and ready-issue selection. All of it is reachable through `--dry-run`, which is the one path that
# never calls `claude -p` with a real prompt or writes anything -- see the script's own header
# comment and CLAUDE.md's "Scheduled review job" section for the thresholds asserted below.
#
# What this suite deliberately does NOT do: verify the actual analysis/implementation run, or how
# `claude -p` / `gh issue create` / `gh pr create` behave for real. Those need live network and API
# access and are out of scope (see issue #150) -- this only exercises the pure arithmetic and
# threshold checks that decide what a run *would* do.
#
# CI runs this under bash 5; macOS ships bash 3.2, and `set -u` is stricter on the newer one --
# `${unset_var//a/b}` aborts the script on bash 4.2+ but is silently empty on 3.2. A stub that reads
# an unset FAKE_* variable therefore passes locally and fails only in CI (it already has once), so
# default every one of them with `${VAR:-}` rather than trusting a local green run.
#
# run-review.sh hardcodes REPO=/Users/patrick/Dev/pickpic and STATE_DIR=/Users/patrick/.claude/pickpic-review
# (by design -- it's a personal, locally-scheduled job, not general-purpose software). Exercising
# the real script therefore means those exact paths have to exist; the CI workflow makes
# /Users/patrick/Dev/pickpic resolve to the checkout before this suite runs (see check.yml). Running
# this file on Patrick's own machine, where those paths are the live job's real state directory and
# lock, would read and write them for real -- `setup()` below refuses to run outside GitHub Actions
# specifically to prevent that. Do not remove or loosen that guard.

setup() {
  if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
    skip "only safe inside a disposable CI runner -- run-review.sh's hardcoded /Users/patrick paths would collide with the live job's real state on Patrick's own machine"
  fi

  REVIEW_SCRIPT="/Users/patrick/Dev/pickpic/scripts/review/run-review.sh"

  # Fresh slate for every test -- these drive the gh() stub below.
  unset FAKE_GH_READY_ISSUES FAKE_GH_PR_BODIES FAKE_GH_OPEN_PR_COUNT FAKE_GH_UNTRIAGED_COUNT \
    FAKE_GH_REPORT_ISSUE_NUMBERS FAKE_GH_REPORT_BODY FAKE_GH_ISSUE_HISTORY \
    FAKE_GH_ISSUE_LABELS FAKE_UNREAD_FINDINGS
  export FAKE_SESSION_PCT=10

  # Stands in for the real `claude` binary. The script only ever calls `claude -p "/usage"` before
  # DRY_RUN is checked (that's how it learns SESSION_PCT/WEEK_PCT) -- everything else it does under
  # --dry-run is pure bash. Percentages come from FAKE_SESSION_PCT/FAKE_WEEK_PCT, set per test.
  claude() {
    if [[ "$1" == "-p" && "$2" == "/usage" ]]; then
      printf 'Current session: %s%% used, resets Sep 6 at 3:00pm (America/New_York)\n' "${FAKE_SESSION_PCT:-10}"
      printf 'Current week (all models): %s%% used, resets Sep 7 at 12:00am (America/New_York)\n' "${FAKE_WEEK_PCT:-30}"
    else
      printf '(stubbed claude output -- should not be reached under --dry-run)\n'
    fi
  }
  export -f claude

  # Stands in for the real `gh` binary. run-review.sh gathers ready-issue/backlog/open-PR counts
  # via `gh` unconditionally -- even under --dry-run, and even in "daily" mode -- so there is no way
  # to exercise the backlog gate or the sweep-sizing math without a stand-in. Matches on the
  # subcommand and a few distinguishing flags rather than the exact --jq filter text, since this
  # stub returns the already-filtered result the real `gh | jq` pipeline would have produced.
  gh() {
    case "$1 $2" in
      "pr list")
        if [[ "$*" == *"--json body"* ]]; then
          printf '%s' "${FAKE_GH_PR_BODIES:-}"
        else
          printf '%s' "${FAKE_GH_OPEN_PR_COUNT:-0}"
        fi
        ;;
      "issue list")
        if [[ "$*" == *"--label ready"* ]]; then
          # The real query returns "<number> <comma-joined labels>" per line, so depth resolution
          # costs no extra API call. FAKE_GH_READY_ISSUES stays a bare number list (as it was before
          # depth labels existed) and FAKE_GH_ISSUE_LABELS optionally supplies each one's labels as
          # "42=ready,model:sonnet;43=ready,effort:low". An issue absent from the map yields no
          # labels, which is the "unlabelled ready issue" case worth exercising in its own right.
          # The `:-` is load-bearing: run-review.sh runs under `set -u`, and a pattern substitution
          # on an unset variable is an unbound-variable error on bash 4.2+ (though not on macOS's
          # bash 3.2, which is why this passed locally and failed in CI).
          local n e entry map="${FAKE_GH_ISSUE_LABELS:-}"
          for n in ${FAKE_GH_READY_ISSUES:-}; do
            entry=""
            for e in ${map//;/ }; do
              [[ "${e%%=*}" == "$n" ]] && entry="${e#*=}"
            done
            printf '%s %s\n' "$n" "$entry"
          done
        elif [[ "$*" == *"--label review-report"* ]]; then
          # One synthetic report holds the whole unread-findings count unless a test names its own
          # report issues (the trends suite does).
          if [[ -n "${FAKE_GH_REPORT_ISSUE_NUMBERS:-}" ]]; then
            printf '%s' "$FAKE_GH_REPORT_ISSUE_NUMBERS"
          elif [[ "${FAKE_UNREAD_FINDINGS:-0}" -gt 0 ]]; then
            printf '777'
          fi
        elif [[ "$*" == *"--state all"* ]]; then
          printf '%s' "${FAKE_GH_ISSUE_HISTORY:-}"
        else
          printf '%s' "${FAKE_GH_UNTRIAGED_COUNT:-0}"
        fi
        ;;
      "issue view")
        # The backlog metric counts "### <n>" headings in an open report's body, so synthesize a
        # body with exactly FAKE_UNREAD_FINDINGS of them unless the test supplied its own.
        if [[ -n "${FAKE_GH_REPORT_BODY:-}" ]]; then
          printf '%s' "$FAKE_GH_REPORT_BODY"
        else
          local i=1
          while [[ "$i" -le "${FAKE_UNREAD_FINDINGS:-0}" ]]; do
            printf '### %s. finding\n' "$i"
            i=$(( i + 1 ))
          done
        fi
        ;;
      "issue create")
        printf 'https://github.com/Patrick9263/pickpic/issues/9999'
        ;;
      *)
        return 0
        ;;
    esac
  }
  export -f gh
}

# ---------------------------------------------------------------------------
# decide_depth() -- the budget-scaled depth ladder (CLAUDE.md "Budget gates")
# ---------------------------------------------------------------------------

@test "decide_depth: below 45% weekly picks deep/opus/max" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 run bash "$REVIEW_SCRIPT" daily --target test-area --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depth=deep"* ]]
  [[ "$output" == *"kind=analyse target=test-area model=opus effort=max"* ]]
}

@test "decide_depth: 45-64% weekly picks standard/opus/high" {
  FAKE_WEEK_PCT=50 FAKE_UNREAD_FINDINGS=0 run bash "$REVIEW_SCRIPT" daily --target test-area --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depth=standard"* ]]
  [[ "$output" == *"kind=analyse target=test-area model=opus effort=high"* ]]
}

@test "decide_depth: 65-79% weekly picks light/sonnet/medium" {
  FAKE_WEEK_PCT=70 FAKE_UNREAD_FINDINGS=0 run bash "$REVIEW_SCRIPT" daily --target test-area --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depth=light"* ]]
  [[ "$output" == *"kind=analyse target=test-area model=sonnet effort=medium"* ]]
}

@test "decide_depth: 80% weekly or above stands the whole run down" {
  FAKE_WEEK_PCT=85 run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP: weekly window at 85% -- protecting remaining interactive capacity"* ]]
}

# ---------------------------------------------------------------------------
# Budget gates specific to surplus mode and the shared backlog gate
# ---------------------------------------------------------------------------

@test "surplus mode stands down when weekly is at or above 60%" {
  FAKE_WEEK_PCT=65 run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP: surplus run needs weekly < 60%, currently 65%"* ]]
}

@test "any mode stands down once unread findings exceed 15" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=16 run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP: 16 unread findings already waiting -- not adding more"* ]]
}

# The backlog metric counts unread findings inside open reports, NOT hand-filed issues. Patrick's own
# feature backlog used to push this count past the ceiling and stand the weekday run down -- his own
# planning switching off the job meant to help with it.
@test "the backlog gate ignores hand-filed unlabelled issues" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_UNTRIAGED_COUNT=40 \
    run bash "$REVIEW_SCRIPT" daily --target test-area --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"backlog: 0 unread finding(s)"* ]]
  [[ "$output" != *"SKIP"* ]]
}

# ---------------------------------------------------------------------------
# Surplus sweep sizing: BACKLOG_TARGET tiers and the (target - untriaged) / 3 scan count
# ---------------------------------------------------------------------------

@test "sweep sizing: empty backlog on a good week books the full deficit" {
  # target 12 (week < 45%), unread 0 -> deficit 12 -> ceil(12/3) = 4 scans
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=sweep target=sweep of 4 areas"* ]]
}

@test "sweep sizing: a near-full backlog only books one scan" {
  # target 8 (45% <= week < 60%), unread 6 -> deficit 2, clamped to the 3 floor -> ceil(3/3) = 1 scan
  FAKE_WEEK_PCT=50 FAKE_UNREAD_FINDINGS=6 run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=sweep target=sweep of 1 areas"* ]]
}

@test "sweep sizing: a backlog already at target is clamped to the 3-entry floor" {
  # target 8 (45% <= week < 60%), unread 8 -> raw deficit 0, clamped to 3 -> ceil(3/3) = 1 scan.
  # Without the floor this would round down to 0 scans and the sweep would find nothing.
  FAKE_WEEK_PCT=50 FAKE_UNREAD_FINDINGS=8 run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=sweep target=sweep of 1 areas"* ]]
}

# ---------------------------------------------------------------------------
# Surplus ready-issue selection
# ---------------------------------------------------------------------------

@test "surplus mode implements a ready issue that has no open PR yet" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 FAKE_GH_OPEN_PR_COUNT=1 \
    run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=implement queue=42"* ]]
  [[ "$output" == *"DRY RUN -- would implement ready issues: 42"* ]]
}

@test "surplus mode skips a ready issue that already has an open PR, falling back to a sweep" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 \
    FAKE_GH_PR_BODIES="Closes #42" FAKE_GH_OPEN_PR_COUNT=1 \
    run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping ready issue #42 -- already has an open PR"* ]]
  [[ "$output" == *"kind=sweep target=sweep of 4 areas"* ]]
}

# ---------------------------------------------------------------------------
# Weekday (daily) implementation
#
# Implementing used to be surplus-only, so the Mon-Thu runs could only ever add to the backlog they
# were standing down because of.
# ---------------------------------------------------------------------------

@test "daily mode implements a ready issue instead of analysing" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 \
    FAKE_GH_ISSUE_LABELS="42=ready,model:sonnet,effort:medium" \
    run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=implement queue=42"* ]]
  [[ "$output" != *"kind=analyse"* ]]
}

@test "daily mode with an empty ready queue still analyses" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 run bash "$REVIEW_SCRIPT" daily --target test-area --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=analyse target=test-area"* ]]
}

# Implementation is the expensive path; above 70% weekly the weekday run leaves the queue alone and
# falls through to the cheaper analysis rather than starting work it may not finish.
@test "daily mode does not implement above 70% weekly" {
  FAKE_WEEK_PCT=72 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 \
    run bash "$REVIEW_SCRIPT" daily --target test-area --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"not implementing this run: weekly at 72%"* ]]
  [[ "$output" == *"kind=analyse target=test-area"* ]]
}

# ---------------------------------------------------------------------------
# resolve_issue_depth(): the ladder as a ceiling, and the labels that size an issue
# ---------------------------------------------------------------------------

# The cost saving. A cheap issue costs cheap even on a morning the ladder would have spent opus/max.
@test "a below-ladder declaration is honoured verbatim" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 \
    FAKE_GH_ISSUE_LABELS="42=ready,model:haiku,effort:low" \
    run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depths=haiku/low"* ]]
  [[ "$output" == *"ceiling=opus/max"* ]]
}

# The other half of the point: a hard issue waits for a morning that can afford it rather than being
# attempted by a weaker model, because a bad unattended PR costs more review time than an absent one.
#
# 65% is the one window where this is observable: the ladder is light (sonnet/medium) but the
# weekday implement gate (<70%) is still open. Surplus cannot be used here -- it stands down
# entirely at 60%, so the run would never reach the queue.
@test "an above-ladder declaration defers instead of being downgraded" {
  FAKE_WEEK_PCT=65 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 \
    FAKE_GH_ISSUE_LABELS="42=ready,model:opus,effort:max" \
    run bash "$REVIEW_SCRIPT" daily --target test-area --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"deferring ready issue #42"* ]]
  # Nothing left to implement, so the run falls through to analysis rather than doing nothing.
  [[ "$output" == *"kind=analyse target=test-area"* ]]
}

# Oldest-first ordering means an expensive issue sits at the front of the queue; it must not block
# the cheap ones behind it, so deferral is per-issue rather than a break out of the loop.
@test "a deferred issue does not block a cheaper one behind it" {
  FAKE_WEEK_PCT=50 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES="42 43" \
    FAKE_GH_ISSUE_LABELS="42=ready,model:opus,effort:max;43=ready,model:sonnet,effort:low" \
    run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"deferring ready issue #42"* ]]
  [[ "$output" == *"kind=implement queue=43"* ]]
}

# Depth labels cannot be guaranteed present -- an outside contributor on this public repo cannot
# apply labels at all. Defaulting to the ladder would mean a forgotten label draws opus/max.
@test "an unlabelled ready issue defaults to sonnet/medium, not to the ladder" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 \
    FAKE_GH_ISSUE_LABELS="42=ready" \
    run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no model: label"* ]]
  [[ "$output" == *"depths=sonnet/medium"* ]]
}

@test "an unrecognised label value reads as absent rather than reaching the CLI" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 \
    FAKE_GH_ISSUE_LABELS="42=ready,model:gpt,effort:turbo" \
    run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depths=sonnet/medium"* ]]
  [[ "$output" != *"gpt"* ]]
}

# Two labels from one namespace is a triage slip with no sensible resolution, so it is treated as
# absent rather than guessed at.
@test "contradictory labels from one namespace fall back to the default" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 \
    FAKE_GH_ISSUE_LABELS="42=ready,model:opus,model:haiku" \
    run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"contradictory model: labels"* ]]
  [[ "$output" == *"depths=sonnet/medium"* ]]
}

# Each namespace defaults independently, so `model:` alone is a valid, meaningful declaration.
@test "one namespace alone still cheapens that half" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 \
    FAKE_GH_ISSUE_LABELS="42=ready,model:haiku" \
    run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depths=haiku/medium"* ]]
}

# The default is itself ladder-capped: on a light day it must not run richer than the day affords.
@test "the sonnet/medium default is still capped by a light ladder" {
  FAKE_WEEK_PCT=50 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES=42 \
    FAKE_GH_ISSUE_LABELS="42=ready" \
    run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depths=sonnet/medium"* ]]
  [[ "$output" == *"ceiling=opus/high"* ]]
}

# ---------------------------------------------------------------------------
# The weight budget: how much a single run may take on
#
# Measured in resolved effort rank (low 1, medium 2, high 3, max 4) rather than issue count, so that
# four one-line fixes and four cross-file rewrites are not treated as the same morning's work.
# ---------------------------------------------------------------------------

@test "weight budget: four low-effort issues all fit a weekday run" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES="41 42 43 44" \
    FAKE_GH_ISSUE_LABELS="41=ready,effort:low;42=ready,effort:low;43=ready,effort:low;44=ready,effort:low" \
    run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=implement queue=41 42 43 44"* ]]
  [[ "$output" == *"weight=4/4"* ]]
}

# The "large PRs don't pile up" property, stated directly: 3 + 3 exceeds the weekday budget of 4.
@test "weight budget: two high-effort issues do not fit one weekday run" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES="42 43" \
    FAKE_GH_ISSUE_LABELS="42=ready,effort:high;43=ready,effort:high" \
    run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=implement queue=42"* ]]
  [[ "$output" == *"issue #43 does not fit this run's remaining weight"* ]]
}

# An oversized issue is left in place for the next run, not dropped -- so a smaller one behind it can
# still take the remaining weight without the queue losing its oldest-first order across runs.
@test "weight budget: an oversized issue is passed over, not dropped" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES="42 43 44" \
    FAKE_GH_ISSUE_LABELS="42=ready,effort:high;43=ready,effort:max;44=ready,effort:low" \
    run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"issue #43 does not fit this run's remaining weight"* ]]
  [[ "$output" == *"kind=implement queue=42 44"* ]]
  [[ "$output" == *"weight=4/4"* ]]
}

# Draining is surplus's whole purpose, so it carries a larger budget than a weekday run.
@test "weight budget: surplus admits more than a weekday run" {
  FAKE_WEEK_PCT=30 FAKE_UNREAD_FINDINGS=0 FAKE_GH_READY_ISSUES="42 43" \
    FAKE_GH_ISSUE_LABELS="42=ready,effort:high;43=ready,effort:high" \
    run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=implement queue=42 43"* ]]
  [[ "$output" == *"weight=6/10"* ]]
}

# ---------------------------------------------------------------------------
# Trends mode: render_bar_chart() and the dry-run gate that stops before the real
# `claude -p`/`gh issue create` calls (previously trends mode had no such gate at all -- unlike
# every other mode, `trends --dry-run` fell straight through to a real analysis and a real issue).
# ---------------------------------------------------------------------------

@test "trends mode: dry run prints a bar chart per run from metrics.csv and never reaches claude or gh issue create" {
  local metrics_file="/Users/patrick/.claude/pickpic-review/metrics.csv"
  local backup=""
  if [[ -f "$metrics_file" ]]; then
    backup="$(mktemp)"
    cp "$metrics_file" "$backup"
  fi
  mkdir -p "$(dirname "$metrics_file")"
  {
    printf 'timestamp,mode,kind,target,outcome,model,effort,scans,findings,week_before,week_after,week_delta,session_before,session_after,duration_s,issue,issue_private\n'
    printf '2026-09-01T00:00:00-0400,daily,analyse,"a",ok,opus,high,1,3,10,14,4,1,2,100,1,\n'
    printf '2026-09-02T00:00:00-0400,daily,analyse,"b",ok,opus,high,1,2,14,20,6,1,2,100,2,\n'
    # week_before (2) lower than the previous row's week_after (20) -- a weekly reset happened
    # between these two runs, and the chart should label that row rather than plot a silent cliff.
    printf '2026-09-08T00:00:00-0400,daily,analyse,"c",ok,opus,high,1,1,2,6,4,1,2,100,3,\n'
  } >"$metrics_file"

  FAKE_WEEK_PCT=30 run bash "$REVIEW_SCRIPT" trends --dry-run

  if [[ -n "$backup" ]]; then
    mv "$backup" "$metrics_file"
  else
    rm -f "$metrics_file"
  fi

  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN -- would post trends issue covering 3 runs"* ]]
  [[ "$output" == *"weekly budget after each run:"* ]]
  # Budget is on its real, fixed 0-100% scale (not renormalized to the sample's own min/max).
  [[ "$output" == *"09-01 00:00  ##.............   14%"* ]]
  [[ "$output" == *"09-02 00:00  ###............   20%"* ]]
  [[ "$output" == *"09-08 00:00  ...............    6%  (week reset)"* ]]
  [[ "$output" == *"weekly cost per run:"* ]]
  # Cost has no fixed ceiling, so it scales against the largest value actually recorded (6).
  [[ "$output" == *"09-01 00:00  ##########.....    4"* ]]
  [[ "$output" == *"09-02 00:00  ###############    6"* ]]
  [[ "$output" == *"09-08 00:00  ##########.....    4  (week reset)"* ]]
}

@test "trends mode: a full run closes each chart's code fence on its own line" {
  # Regression test: command substitution strips $BUDGET_CHART/$COST_CHART's trailing newline, so
  # an earlier version of the printf wrapping them produced a closing \`\`\` glued to the last data
  # row instead of on its own line -- which GitHub does not parse as closing the fence, so
  # everything after it (the rest of the issue body) silently renders as part of the code block.
  # Only the full (non-dry-run) path builds that body, so this can't be caught under --dry-run.
  local metrics_file="/Users/patrick/.claude/pickpic-review/metrics.csv"
  local backup=""
  if [[ -f "$metrics_file" ]]; then
    backup="$(mktemp)"
    cp "$metrics_file" "$backup"
  fi
  mkdir -p "$(dirname "$metrics_file")"
  printf 'timestamp,mode,kind,target,outcome,model,effort,scans,findings,week_before,week_after,week_delta,session_before,session_after,duration_s,issue,issue_private\n' >"$metrics_file"
  printf '2026-09-01T00:00:00-0400,daily,analyse,"a",ok,opus,high,1,3,10,14,4,1,2,100,1,\n' >>"$metrics_file"

  # Overrides setup()'s claude() stub for this test only: the real (non-dry-run) trends path also
  # calls claude for the analysis prompt itself, not just /usage.
  claude() {
    if [[ "$1" == "-p" && "$2" == "/usage" ]]; then
      printf 'Current session: %s%% used, resets Sep 6 at 3:00pm (America/New_York)\n' "${FAKE_SESSION_PCT:-10}"
      printf 'Current week (all models): %s%% used, resets Sep 7 at 12:00am (America/New_York)\n' "${FAKE_WEEK_PCT:-30}"
    else
      printf 'Fake trends report body.\n\n**Verdict:** Worth it.\n'
    fi
  }
  export -f claude

  FAKE_WEEK_PCT=30 run bash "$REVIEW_SCRIPT" trends

  local body_file="/Users/patrick/.claude/pickpic-review/.trends-body.md"
  local fence_lines=0
  [[ -f "$body_file" ]] && fence_lines="$(grep -c '^```$' "$body_file" || true)"

  if [[ -n "$backup" ]]; then
    mv "$backup" "$metrics_file"
  else
    rm -f "$metrics_file"
  fi

  [ "$status" -eq 0 ]
  # Two charts, each opening and closing a fence -- four lines that are exactly \`\`\` and nothing else.
  [ "$fence_lines" -eq 4 ]
}

@test "trends mode: no recorded metrics stands the run down before touching gh or claude" {
  local metrics_file="/Users/patrick/.claude/pickpic-review/metrics.csv"
  local backup=""
  if [[ -f "$metrics_file" ]]; then
    backup="$(mktemp)"
    cp "$metrics_file" "$backup"
    rm -f "$metrics_file"
  fi

  FAKE_WEEK_PCT=30 run bash "$REVIEW_SCRIPT" trends --dry-run

  if [[ -n "$backup" ]]; then
    mv "$backup" "$metrics_file"
  fi

  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP: no metrics recorded yet"* ]]
}

# ---------------------------------------------------------------------------
# count_findings(): grep -c on an existing zero-match file must read as "0", not "0\n0"
# ---------------------------------------------------------------------------
# grep -c prints "0" but still exits 1 when a file exists with no matches -- only a missing file
# fails to print anything. A `grep -c ... || echo 0` fallback can't tell those apart: on the
# zero-match case it appends a second "0", so $(( $(...) + $(...) )) sees "0\n0" as one operand and
# dies with "syntax error in expression", which is exactly what left every FINDINGS_COUNT and every
# metrics.csv `findings` column blank in production. Sourced directly (not run through the full
# script) since the surrounding publish flow only runs past --dry-run and is out of scope for this
# suite (see the file header and issue #150).
@test "count_findings reads a zero-match file as 0, not 0\\n0" {
  eval "$(sed -n '/^count_findings() {/,/^}/p' "$REVIEW_SCRIPT")"
  local empty_report="$BATS_TEST_TMPDIR/empty-report.md"
  printf 'nothing found this run\n' >"$empty_report"

  result="$(count_findings "$empty_report")"
  [ "$result" = "0" ]

  result="$(count_findings "$BATS_TEST_TMPDIR/does-not-exist.md")"
  [ "$result" = "0" ]

  # The bug only ever surfaces once the value is actually used in arithmetic.
  total=$(( $(count_findings "$empty_report") + $(count_findings "$empty_report") ))
  [ "$total" -eq 0 ]
}

@test "count_findings counts real findings headings" {
  eval "$(sed -n '/^count_findings() {/,/^}/p' "$REVIEW_SCRIPT")"
  local report="$BATS_TEST_TMPDIR/report.md"
  printf '### 1. First finding\n\nbody\n\n### 2. Second finding\n' >"$report"

  result="$(count_findings "$report")"
  [ "$result" = "2" ]
}
