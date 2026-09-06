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
    FAKE_GH_REPORT_ISSUE_NUMBERS FAKE_GH_REPORT_BODY FAKE_GH_ISSUE_HISTORY
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
          printf '%s' "${FAKE_GH_READY_ISSUES:-}"
        elif [[ "$*" == *"--label review-report"* ]]; then
          printf '%s' "${FAKE_GH_REPORT_ISSUE_NUMBERS:-}"
        elif [[ "$*" == *"--state all"* ]]; then
          printf '%s' "${FAKE_GH_ISSUE_HISTORY:-}"
        else
          printf '%s' "${FAKE_GH_UNTRIAGED_COUNT:-0}"
        fi
        ;;
      "issue view")
        printf '%s' "${FAKE_GH_REPORT_BODY:-}"
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
  FAKE_WEEK_PCT=30 FAKE_GH_UNTRIAGED_COUNT=0 run bash "$REVIEW_SCRIPT" daily --target test-area --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depth=deep"* ]]
  [[ "$output" == *"kind=analyse target=test-area model=opus effort=max"* ]]
}

@test "decide_depth: 45-64% weekly picks standard/opus/high" {
  FAKE_WEEK_PCT=50 FAKE_GH_UNTRIAGED_COUNT=0 run bash "$REVIEW_SCRIPT" daily --target test-area --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"depth=standard"* ]]
  [[ "$output" == *"kind=analyse target=test-area model=opus effort=high"* ]]
}

@test "decide_depth: 65-79% weekly picks light/sonnet/medium" {
  FAKE_WEEK_PCT=70 FAKE_GH_UNTRIAGED_COUNT=0 run bash "$REVIEW_SCRIPT" daily --target test-area --dry-run
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

@test "any mode stands down once the untriaged backlog exceeds 15" {
  FAKE_WEEK_PCT=30 FAKE_GH_UNTRIAGED_COUNT=16 run bash "$REVIEW_SCRIPT" daily --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP: 16 untriaged open issues already -- not adding more"* ]]
}

# ---------------------------------------------------------------------------
# Surplus sweep sizing: BACKLOG_TARGET tiers and the (target - untriaged) / 3 scan count
# ---------------------------------------------------------------------------

@test "sweep sizing: empty backlog on a good week books the full deficit" {
  # target 24 (week < 45%), untriaged 0 -> deficit 24 -> ceil(24/3) = 8 scans
  FAKE_WEEK_PCT=30 FAKE_GH_UNTRIAGED_COUNT=0 run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=sweep target=sweep of 8 areas"* ]]
}

@test "sweep sizing: a near-full backlog only books one scan" {
  # target 15 (45% <= week < 60%), untriaged 12 -> deficit 3 -> ceil(3/3) = 1 scan
  FAKE_WEEK_PCT=50 FAKE_GH_UNTRIAGED_COUNT=12 run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=sweep target=sweep of 1 areas"* ]]
}

@test "sweep sizing: a backlog already at target is clamped to the 3-entry floor" {
  # target 15 (45% <= week < 60%), untriaged 15 (right at the 15-untriaged backlog ceiling, so the
  # run isn't stood down entirely) -> raw deficit 0, clamped to 3 -> ceil(3/3) = 1 scan.
  # Without the floor this would round down to 0 scans and the sweep would find nothing.
  FAKE_WEEK_PCT=50 FAKE_GH_UNTRIAGED_COUNT=15 run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=sweep target=sweep of 1 areas"* ]]
}

# ---------------------------------------------------------------------------
# Surplus ready-issue selection
# ---------------------------------------------------------------------------

@test "surplus mode implements a ready issue that has no open PR yet" {
  FAKE_WEEK_PCT=30 FAKE_GH_UNTRIAGED_COUNT=0 FAKE_GH_READY_ISSUES=42 FAKE_GH_OPEN_PR_COUNT=1 \
    run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind=implement target=issue #42"* ]]
  [[ "$output" == *"DRY RUN -- would invoke claude with prompt"* ]]
  [[ "$output" == *"surplus.md"* ]]
}

@test "surplus mode skips a ready issue that already has an open PR, falling back to a sweep" {
  FAKE_WEEK_PCT=30 FAKE_GH_UNTRIAGED_COUNT=0 FAKE_GH_READY_ISSUES=42 \
    FAKE_GH_PR_BODIES="Closes #42" FAKE_GH_OPEN_PR_COUNT=1 \
    run bash "$REVIEW_SCRIPT" surplus --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping ready issue #42 -- already has an open PR"* ]]
  [[ "$output" == *"kind=sweep target=sweep of 8 areas"* ]]
}
