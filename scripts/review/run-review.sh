#!/bin/bash
#
# Scheduled PickPic review job.
#
# Runs an unattended Claude analysis of the codebase and posts the suggestions as a single GitHub
# issue for triage. Invoked by the two LaunchAgents described in CLAUDE.md; also safe to run by hand.
#
#   run-review.sh daily      rotating single-surface analysis  (Mon-Thu 6:10am)
#   run-review.sh surplus    ready-issue implementation, else full sweep  (Fri/Sat 6:10am)
#   run-review.sh <mode> --dry-run    print the decision and exit without calling Claude
#
# The governing constraint is budget: Patrick's interactive daytime capacity comes first, so this
# job refuses to run rather than eating into it. See the gates in decide_depth() below.

set -euo pipefail

REPO="/Users/patrick/Dev/pickpic"
STATE_DIR="/Users/patrick/.claude/pickpic-review"
REPORTS_DIR="$STATE_DIR/reports"
LOG_FILE="$STATE_DIR/logs/run-$(date +%Y-%m).log"
LOCK_DIR="$STATE_DIR/.lock"

# launchd starts jobs with a minimal PATH, and none of node/npm/gh resolve without this.
export PATH="/Users/patrick/.local/bin:/Users/patrick/.nvm/versions/node/v26.5.1/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Re-exec from a snapshot outside the repo before doing anything else.
#
# bash reads a script lazily, by byte offset, as it executes. This script lives in the working tree
# it operates on, so an implementation run that checks out another branch would rewrite or delete
# the very file bash is mid-way through reading -- and bash would then execute whatever bytes now
# sit at that offset. Copying to a fixed location first makes the running copy immune to anything
# git does to the tree.
SNAPSHOT="$STATE_DIR/.run-review.snapshot.sh"
if [[ "${REVIEW_SNAPSHOTTED:-}" != "1" ]]; then
  mkdir -p "$STATE_DIR"
  cp "$0" "$SNAPSHOT"
  chmod +x "$SNAPSHOT"
  export REVIEW_SNAPSHOTTED=1
  exec "$SNAPSHOT" "$@"
fi

MODE="${1:-daily}"
DRY_RUN="no"
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN="yes"

mkdir -p "$REPORTS_DIR" "$(dirname "$LOG_FILE")"

log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Single-instance guard
# ---------------------------------------------------------------------------
# mkdir is atomic, which the usual `[ -f lockfile ]` test is not. A deferred run can sleep for hours,
# so a second job firing meanwhile is a real possibility rather than a theoretical one.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "SKIP: another review run holds the lock ($LOCK_DIR)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------
# One row per run, written from the EXIT trap so that skips and failures are recorded as faithfully
# as successes -- how often the job stands down, and why, is the more interesting trend than how
# much a successful run cost.
#
# The budget figures are integer percentages, so a single run's delta is coarse (one to three
# points). Over weeks that is still enough to answer the questions worth asking: whether sweeps are
# getting more expensive, whether the depth ladder picks sensible models, and how much of the weekly
# window this job is really consuming.
METRICS_FILE="$STATE_DIR/metrics.csv"
START_EPOCH="$(date +%s)"
RUN_OUTCOME="unknown"
SCANS_DONE=0
FINDINGS_COUNT=""
ISSUE_REF=""

record_metrics() {
  [[ "$DRY_RUN" == "yes" ]] && return 0
  if [[ ! -f "$METRICS_FILE" ]]; then
    printf 'timestamp,mode,kind,target,outcome,model,effort,scans,findings,week_before,week_after,week_delta,session_before,session_after,duration_s,issue\n' >"$METRICS_FILE"
  fi
  local wb="${BUDGET_BEFORE_WEEK:-}" wa="${BUDGET_AFTER_WEEK:-}" wd=""
  [[ -n "$wb" && -n "$wa" && "$wa" != "?" ]] && wd=$(( wa - wb ))
  printf '%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$MODE" "${RUN_KIND:-}" "${TARGET:-}" "$RUN_OUTCOME" \
    "${MODEL:-}" "${EFFORT:-}" "$SCANS_DONE" "$FINDINGS_COUNT" \
    "$wb" "$wa" "$wd" "${BUDGET_BEFORE_SESSION:-}" "${BUDGET_AFTER_SESSION:-}" \
    "$(( $(date +%s) - START_EPOCH ))" "$ISSUE_REF" >>"$METRICS_FILE"
}

# An implementation run checks out main and branches from it, leaving the working tree somewhere
# else when it finishes. Every scheduled run afterwards invokes this script by absolute path from
# that same tree, so if the branch it lands on does not contain the script, the next run dies with a
# missing-file error and the job silently stops until someone notices. Put the tree back.
ORIGINAL_BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

restore_branch() {
  [[ "${RUN_KIND:-}" != "implement" || -z "$ORIGINAL_BRANCH" ]] && return 0
  local now
  now="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -z "$now" || "$now" == "$ORIGINAL_BRANCH" ]] && return 0
  # Never discard work to get back. A dirty tree here means the run did not finish cleanly, and the
  # uncommitted changes are worth more than the convenience of an automatic restore.
  if [[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]]; then
    log "WARNING: tree is dirty on $now, leaving it alone. Scheduled runs will fail until the tree is back on a branch holding this script."
    return 0
  fi
  if git -C "$REPO" checkout -q "$ORIGINAL_BRANCH" 2>/dev/null; then
    log "restored working tree to $ORIGINAL_BRANCH"
  else
    log "WARNING: could not restore $ORIGINAL_BRANCH from $now"
  fi
}

trap 'restore_branch; record_metrics; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------

USAGE_RAW=""

# Populates USAGE_RAW plus SESSION_PCT / WEEK_PCT / SESSION_RESET / WEEK_RESET.
# Percentages come back as integers; `/usage` offers no finer resolution on a subscription, and
# there is no per-run dollar figure to report.
read_usage() {
  USAGE_RAW="$(claude -p "/usage" 2>&1 || true)"

  SESSION_PCT="$(printf '%s' "$USAGE_RAW" | sed -n 's/.*Current session: \([0-9]\{1,3\}\)% used.*/\1/p' | head -1)"
  WEEK_PCT="$(printf '%s' "$USAGE_RAW" | sed -n 's/.*Current week (all models): \([0-9]\{1,3\}\)% used.*/\1/p' | head -1)"
  SESSION_RESET="$(printf '%s' "$USAGE_RAW" | sed -n 's/.*Current session:.*resets \(.*\) (.*/\1/p' | head -1)"
  WEEK_RESET="$(printf '%s' "$USAGE_RAW" | sed -n 's/.*Current week (all models):.*resets \(.*\) (.*/\1/p' | head -1)"
}

# Fail closed on an unparseable /usage rather than guessing. Spending budget blind is the one
# outcome this job exists to prevent -- but log loudly, because a silent permanent stop looks
# identical to "nothing worth reporting" from the outside. If reports stop arriving, read this log.
require_budget() {
  if [[ -z "${SESSION_PCT:-}" || -z "${WEEK_PCT:-}" ]]; then
    RUN_OUTCOME="abort-unparseable-usage"
    log "ABORT: could not parse /usage output -- the format may have changed. Raw output follows:"
    printf '%s\n' "$USAGE_RAW" | tee -a "$LOG_FILE"
    exit 1
  fi
}

# "Sep 3 at 10:09pm" -> epoch seconds. macOS `date` has no -d, so the format string is explicit.
# Falls back to empty on any parse failure; callers treat that as "cannot defer".
reset_to_epoch() {
  local when="${1// at /  }"
  local epoch
  epoch="$(date -j -f "%b %d  %I:%M%p" "$when" +%s 2>/dev/null || true)"
  [[ -z "$epoch" ]] && return 0
  # No year in the string, so `date` assumes the current one; a reset that lands "in the past" is
  # really tomorrow (or next year, across Dec 31).
  if [[ "$epoch" -lt "$(date +%s)" ]]; then
    epoch=$((epoch + 86400))
  fi
  printf '%s' "$epoch"
}

# ---------------------------------------------------------------------------
# Depth ladder
# ---------------------------------------------------------------------------
# A good week buys a better review. Below 45% weekly there is room for Opus at max effort; past 80%
# the job stands down entirely so the rest of the window stays available for interactive work.
decide_depth() {
  if [[ "$WEEK_PCT" -ge 80 ]]; then
    DEPTH="skip"
  elif [[ "$WEEK_PCT" -lt 45 ]]; then
    DEPTH="deep"; MODEL="opus"; EFFORT="max"
  elif [[ "$WEEK_PCT" -lt 65 ]]; then
    DEPTH="standard"; MODEL="opus"; EFFORT="high"
  else
    DEPTH="light"; MODEL="sonnet"; EFFORT="medium"
  fi
}

# The daily pass rotates so each run goes deep on one surface instead of skimming everything and
# resurfacing the same findings each morning. The whole app is still covered every week.
rotation_target() {
  case "$(date +%u)" in
    1) echo "worker" ;;
    2) echo "src" ;;
    3) echo "ipad" ;;
    *) echo "cross-cutting" ;;
  esac
}

# ---------------------------------------------------------------------------
# Decide what this run does
# ---------------------------------------------------------------------------

read_usage
require_budget
decide_depth

BUDGET_BEFORE_WEEK="$WEEK_PCT"
BUDGET_BEFORE_SESSION="$SESSION_PCT"

log "mode=$MODE week=${WEEK_PCT}% session=${SESSION_PCT}% depth=$DEPTH"

if [[ "$DEPTH" == "skip" ]]; then
  RUN_OUTCOME="skip-weekly-ceiling"
  log "SKIP: weekly window at ${WEEK_PCT}% -- protecting remaining interactive capacity"
  exit 0
fi

# The surplus run exists to drain an old weekly window before it expires, so it is only worth firing
# when there is genuine surplus to drain.
if [[ "$MODE" == "surplus" && "$WEEK_PCT" -ge 60 ]]; then
  RUN_OUTCOME="skip-no-surplus"
  log "SKIP: surplus run needs weekly < 60%, currently ${WEEK_PCT}%"
  exit 0
fi

# Defer across a session reset, never across a weekly one. A session window is <=5h and resets the
# same morning, so sleeping through it still lands a useful report. Crossing a *weekly* reset would
# mean spending next week's budget early, which is the specific thing this job must not do.
if [[ "$MODE" == "surplus" && "$SESSION_PCT" -ge 70 ]]; then
  RESET_EPOCH="$(reset_to_epoch "$SESSION_RESET")"
  if [[ -n "$RESET_EPOCH" ]]; then
    WAIT=$(( RESET_EPOCH - $(date +%s) + 300 ))
    if [[ "$WAIT" -gt 0 && "$WAIT" -le 19800 ]]; then # 5.5h cap = one session window
      log "DEFER: session at ${SESSION_PCT}%, sleeping ${WAIT}s until the window resets"
      [[ "$DRY_RUN" == "yes" ]] || sleep "$WAIT"
      read_usage
      require_budget
      decide_depth
      BUDGET_BEFORE_WEEK="$WEEK_PCT"
      BUDGET_BEFORE_SESSION="$SESSION_PCT"
      log "post-defer: week=${WEEK_PCT}% session=${SESSION_PCT}% depth=$DEPTH"
      [[ "$DEPTH" == "skip" ]] && { log "SKIP after defer"; exit 0; }
    else
      RUN_OUTCOME="skip-defer-too-long"
      log "SKIP: session at ${SESSION_PCT}% and reset is ${WAIT}s away -- beyond the 5.5h defer cap"
      exit 0
    fi
  fi
fi

cd "$REPO"
git fetch --quiet origin main 2>/dev/null || true

# ---------------------------------------------------------------------------
# Trends mode
# ---------------------------------------------------------------------------
# Reads the accumulated metrics and asks whether this job's own settings are right. Runs Sunday
# morning, just after the weekly window resets, so it reports on a completed week and spends from a
# fresh one.
#
# The question it exists to answer is conversion, not cost: what fraction of suggestions actually
# became issues. Cost is already known to be about a point per scan and is not the constraint. If
# most suggestions are ignored the caps are too generous and scans are being wasted; if nearly all
# are taken up, the caps are throttling useful work.
if [[ "$MODE" == "trends" ]]; then
  RUN_KIND="trends"
  TARGET="weekly trends"

  if [[ ! -s "$METRICS_FILE" ]]; then
    RUN_OUTCOME="skip-no-metrics"
    log "SKIP: no metrics recorded yet ($METRICS_FILE)"
    exit 0
  fi

  METRIC_ROWS="$(( $(wc -l <"$METRICS_FILE") - 1 ))"
  log "trends: $METRIC_ROWS recorded runs"

  ISSUE_HISTORY="$(gh issue list --state all --limit 300 \
    --json number,title,state,createdAt,closedAt,labels \
    --jq '.[] | "\(.createdAt[0:10]) #\(.number) [\(.state)] {\(.labels | map(.name) | join("|"))} \(.title)"' \
    2>/dev/null || echo '(unavailable)')"

  STAMP="$(date +%Y-%m-%d)"
  REPORT_FILE="$REPORTS_DIR/$STAMP-trends.md"
  ALLOWED=(Read Grep Glob)

  TRENDS_PROMPT="$(cat "$REPO/scripts/review/prompts/trends.md")

## metrics.csv ($METRIC_ROWS runs recorded)

$(cat "$METRICS_FILE")

## Every issue in the repository, oldest first

Format: created-date #number [state] {labels} title

$ISSUE_HISTORY"

  set +e
  claude -p "$TRENDS_PROMPT" --model "$MODEL" --effort "$EFFORT" \
    --allowedTools "${ALLOWED[@]}" >"$REPORT_FILE" 2>>"$LOG_FILE"
  TRENDS_RC=$?
  set -e
  if [[ "$TRENDS_RC" -ne 0 ]]; then
    RUN_OUTCOME="error-claude-failed"
    log "ERROR: trends analysis failed"
    exit 1
  fi

  read_usage
  BUDGET_AFTER_WEEK="${WEEK_PCT:-?}"
  BUDGET_AFTER_SESSION="${SESSION_PCT:-?}"
  SCANS_DONE=1

  TRENDS_BODY="$STATE_DIR/.trends-body.md"
  {
    printf 'Covering %s recorded runs. Budget for this analysis: weekly %s%% -> %s%%\n\n' \
      "$METRIC_ROWS" "$BUDGET_BEFORE_WEEK" "$BUDGET_AFTER_WEEK"
    printf -- '---\n\n'
    cat "$REPORT_FILE"
  } >"$TRENDS_BODY"

  ISSUE_URL="$(gh issue create --title "Review job trends — $STAMP" \
    --body-file "$TRENDS_BODY" --label review-trends --assignee @me 2>&1)"
  RUN_OUTCOME="ok"
  ISSUE_REF="$(printf '%s' "$ISSUE_URL" | grep -o '[0-9]*$' || true)"
  log "posted: $ISSUE_URL"
  exit 0
fi

# Surplus mode prefers shipping an already-triaged issue over generating more triage work. One issue
# per run only: it fires Friday and Saturday, so two ready issues still become two reviewable PRs.
#
# `review-report` and `review-trends` issues are excluded even when labelled `ready`. Those are
# containers -- a report holds a numbered list of suggestions, not one implementable change -- and
# labelling one `ready` is an easy mistake to make while triaging on a phone. Picking one up makes
# the run implement several unrelated suggestions at once, which is exactly the unreviewable diff
# the one-issue-per-run rule exists to prevent.
#
# Oldest first, so the backlog drains in the order it was filed rather than newest-first, which is
# what `gh issue list` returns by default.
READY_ISSUE=""
if [[ "$MODE" == "surplus" ]]; then
  READY_ISSUE="$(gh issue list --label ready --state open --limit 50 --json number,labels \
    --jq '[.[] | select(([.labels[].name] | any(. == "review-report" or . == "review-trends")) | not)]
          | sort_by(.number) | .[0].number // empty' 2>/dev/null || true)"
fi

# A suggestion generator that outruns triage capacity just creates work, so stand down when the
# untriaged backlog is already large.
UNTRIAGED="$(gh issue list --state open --limit 100 --json number,labels --jq '[.[] | select(.labels | length == 0)] | length' 2>/dev/null || echo 0)"

# Suggestions waiting inside an open report count as backlog too.
#
# Without this the backlog metric can never rise from this job's own output: a sweep posts ONE issue
# and labels it `review-report`, so it never lands in the unlabelled count above. Every subsequent
# run would then see an empty backlog and scan at full width forever, regardless of how many
# untriaged suggestions were already sitting in reports nobody had read yet.
PENDING_IN_REPORTS=0
for n in $(gh issue list --label review-report --state open --limit 20 --json number --jq '.[].number' 2>/dev/null); do
  c="$(gh issue view "$n" --json body --jq '.body' 2>/dev/null | grep -c '^### [0-9]' || true)"
  PENDING_IN_REPORTS=$(( PENDING_IN_REPORTS + c ))
done
UNTRIAGED=$(( UNTRIAGED + PENDING_IN_REPORTS ))
log "backlog: $UNTRIAGED untriaged ($PENDING_IN_REPORTS of them inside open reports)"
if [[ -z "$READY_ISSUE" && "$UNTRIAGED" -gt 15 ]]; then
  RUN_OUTCOME="skip-backlog-full"
  log "SKIP: $UNTRIAGED untriaged open issues already -- not adding more"
  exit 0
fi

if [[ -n "$READY_ISSUE" ]]; then
  RUN_KIND="implement"
  PROMPT_FILE="$REPO/scripts/review/prompts/surplus.md"
  TARGET="issue #$READY_ISSUE"
elif [[ "$MODE" == "surplus" ]]; then
  # Several narrow scans beat one broad one when there is surplus to spend: each spends a full pass
  # of attention on a single surface, and a consolidation step at the end merges and ranks them into
  # one report.
  #
  # Breadth is capped by triage capacity, NOT by budget. A scan measures at roughly one point of the
  # weekly window, so a Saturday sitting at 45% could afford about thirty-five of them -- but nobody
  # can act on a hundred suggestions, and a report too long to read is worth less than a short one.
  # The limit below leaves room for roughly three findings per scan under the same 15-issue ceiling
  # the single-run path already respects.
  RUN_KIND="sweep"
  PROMPT_FILE="$REPO/scripts/review/prompts/daily.md"

  # How full a backlog to aim for. This is the lever: an empty backlog with budget to spare is
  # exactly when it is worth stocking up, because the weekly window expires Sunday whether or not it
  # was used. When the window is already well spent, aim lower and leave the rest for interactive
  # work.
  if [[ "$WEEK_PCT" -lt 45 ]]; then
    BACKLOG_TARGET=24
  elif [[ "$WEEK_PCT" -lt 60 ]]; then
    BACKLOG_TARGET=15
  else
    BACKLOG_TARGET=9
  fi

  # Targets are deliberately finer-grained than the weekday rotation's four. More scans only pay off
  # if each one covers genuinely different ground -- rerunning "worker" five times mostly reproduces
  # the first run's findings, however much budget is left.
  ALL_TARGETS=(
    worker-auth-and-tenancy
    worker-data-and-storage
    worker-api-and-errors
    src-dashboard
    src-gallery
    ipad-pipeline
    ipad-ui
    security
    performance
    accessibility
    ux-and-docs
  )

  BACKLOG_DEFICIT=$(( BACKLOG_TARGET - UNTRIAGED ))
  [[ "$BACKLOG_DEFICIT" -lt 3 ]] && BACKLOG_DEFICIT=3
  # Roughly three findings survive consolidation per scan, so this is the deficit divided by three,
  # rounded up.
  SWEEP_SLOTS=$(( (BACKLOG_DEFICIT + 2) / 3 ))
  [[ "$SWEEP_SLOTS" -gt "${#ALL_TARGETS[@]}" ]] && SWEEP_SLOTS="${#ALL_TARGETS[@]}"
  SWEEP_TARGETS=("${ALL_TARGETS[@]:0:$SWEEP_SLOTS}")
  TARGET="sweep of ${#SWEEP_TARGETS[@]} areas"
else
  RUN_KIND="analyse"
  PROMPT_FILE="$REPO/scripts/review/prompts/daily.md"
  TARGET="$(rotation_target)"
fi

log "kind=$RUN_KIND target=$TARGET model=${MODEL} effort=${EFFORT}"

if [[ "$DRY_RUN" == "yes" ]]; then
  RUN_OUTCOME="dry-run"
  log "DRY RUN -- would invoke claude with prompt $PROMPT_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

STAMP="$(date +%Y-%m-%d)"
REPORT_FILE="$REPORTS_DIR/$STAMP-$MODE.md"

PROMPT="$(sed -e "s|{{TARGET}}|$TARGET|g" -e "s|{{ISSUE}}|${READY_ISSUE:-}|g" "$PROMPT_FILE")"

# Deduplication context, gathered here rather than by the model. The wrapper runs in an ordinary
# shell where `gh` works; an analysis run does not (see the ALLOWED note below), and without this a
# report happily re-proposes things already filed or already declined.
CONTEXT_BLOCK=""
if [[ "$RUN_KIND" != "implement" ]]; then
  EXISTING_ISSUES="$(gh issue list --state all --limit 200 --json number,title,state \
    --jq '.[] | "- #\(.number) [\(.state)] \(.title)"' 2>/dev/null || echo '(unavailable)')"
  RECENT_COMMITS="$(git log --oneline -15 2>/dev/null || echo '(unavailable)')"
  CONTEXT_BLOCK="

## Existing issues — never re-propose any of these

An issue closed without a matching merge was declined. Do not raise it again.

$EXISTING_ISSUES

## Recent commits

$RECENT_COMMITS"
  PROMPT="$PROMPT$CONTEXT_BLOCK"
fi

if [[ "$RUN_KIND" == "implement" ]]; then
  # Xcode overwrites a disk-edited project.pbxproj from its stale in-memory copy and silently drops
  # file references (CLAUDE.md trap 4). An unattended run must never risk that.
  if pgrep -x Xcode >/dev/null 2>&1; then
    PROMPT="$PROMPT

IMPORTANT: Xcode is currently running on this machine. You must NOT edit ipad/PickPic.xcodeproj/project.pbxproj.
If this issue requires adding a new Swift file, stop and report that it was deferred for that reason."
  fi
  # An array, not a space-separated string: several of these rules contain spaces inside the
  # parentheses, and an unquoted string expansion splits them into fragments the CLI then rejects.
  ALLOWED=(Read Grep Glob Edit Write "Bash(git:*)" "Bash(gh:*)" "Bash(npm:*)" "Bash(xcodebuild:*)")
else
  # Analysis gets no Bash at all. `gh` cannot be granted to a headless `-p` run through
  # --allowedTools -- it asks for approval regardless of the rule, and in print mode there is nobody
  # to approve it -- so the wrapper gathers the git and GitHub context itself (just above) and hands
  # it over in the prompt. That also keeps the analysis run genuinely read-only.
  ALLOWED=(Read Grep Glob)
fi

run_claude() {
  local prompt="$1" outfile="$2" rc
  set +e
  claude -p "$prompt" \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --allowedTools "${ALLOWED[@]}" \
    >"$outfile" 2>>"$LOG_FILE"
  rc=$?
  set -e
  return "$rc"
}

if [[ "$RUN_KIND" == "sweep" ]]; then
  SWEEP_ACCUM="$STATE_DIR/.sweep-findings.md"
  : >"$SWEEP_ACCUM"

  for t in "${SWEEP_TARGETS[@]}"; do
    # Re-check between scans rather than trusting the opening reading. A sweep is the longest thing
    # this job does, and the window it is spending can be moved by an interactive session at the
    # same time.
    read_usage
    if [[ -n "${WEEK_PCT:-}" && "$WEEK_PCT" -ge 70 ]]; then
      log "sweep: stopping early at ${WEEK_PCT}% weekly, before scanning $t"
      break
    fi

    SCAN_PROMPT="$(sed -e "s|{{TARGET}}|$t|g" -e "s|{{ISSUE}}||g" "$PROMPT_FILE")$CONTEXT_BLOCK"
    if [[ -s "$SWEEP_ACCUM" ]]; then
      SCAN_PROMPT="$SCAN_PROMPT

## Already found earlier in this same sweep — do not repeat any of these

$(cat "$SWEEP_ACCUM")"
    fi

    log "sweep: scanning $t"
    if run_claude "$SCAN_PROMPT" "$REPORTS_DIR/$STAMP-sweep-$t.md"; then
      SCANS_DONE=$(( SCANS_DONE + 1 ))
      printf '\n## From the %s scan\n\n' "$t" >>"$SWEEP_ACCUM"
      cat "$REPORTS_DIR/$STAMP-sweep-$t.md" >>"$SWEEP_ACCUM"
    else
      log "sweep: $t scan failed, continuing"
    fi
  done

  if [[ ! -s "$SWEEP_ACCUM" ]]; then
    RUN_OUTCOME="error-no-findings"
    log "ERROR: sweep produced no findings"
    exit 1
  fi

  # Consolidate. Without this the report is N concatenated lists with their own numbering and
  # overlapping findings, which is exactly the unreadable output the slot cap exists to avoid.
  log "sweep: consolidating"
  CONSOLIDATE_PROMPT="Below are findings from several independent scans of the PickPic codebase,
each covering a different area. Merge them into ONE ranked report.

Rules:
- Combine duplicates and near-duplicates into a single entry, keeping the clearest wording.
- Drop anything trivial or speculative. Quality over completeness.
- Keep at most $BACKLOG_DEFICIT entries. If there are more, keep the best ones. Do not pad to reach
  that number — a shorter honest report is better than a padded one.
- Renumber from 1, ordered by value, most worth doing first.
- Preserve each entry's What / Why it matters / Where / Size structure verbatim where you can.
- Output only the merged markdown report. No preamble, no commentary about merging.
- End with a single line '**Recommended next:**' naming the one entry to do first and why.

$(cat "$SWEEP_ACCUM")"

  if ! run_claude "$CONSOLIDATE_PROMPT" "$REPORT_FILE"; then
    log "consolidation failed -- falling back to the raw concatenated findings"
    cp "$SWEEP_ACCUM" "$REPORT_FILE"
  fi
else
  SCANS_DONE=1
  if ! run_claude "$PROMPT" "$REPORT_FILE"; then
    RUN_OUTCOME="error-claude-failed"
    log "ERROR: claude failed -- see $REPORT_FILE and this log"
    exit 1
  fi
fi

read_usage
BUDGET_AFTER_WEEK="${WEEK_PCT:-?}"
BUDGET_AFTER_SESSION="${SESSION_PCT:-?}"

WEEK_DELTA="?"
[[ "$BUDGET_AFTER_WEEK" != "?" ]] && WEEK_DELTA=$(( BUDGET_AFTER_WEEK - BUDGET_BEFORE_WEEK ))

log "done: week ${BUDGET_BEFORE_WEEK}% -> ${BUDGET_AFTER_WEEK}% (+${WEEK_DELTA} pts)"

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------
# An implementation run opens its own PR, so there is nothing further to post.
if [[ "$RUN_KIND" == "implement" ]]; then
  RUN_OUTCOME="ok-implement"
  log "implementation run finished for $TARGET; PR handling was Claude's responsibility"
  exit 0
fi

ISSUE_BODY="$STATE_DIR/.issue-body.md"
{
  printf 'Budget: weekly %s%% -> %s%% used (+%s pts) - session %s%% -> %s%% - weekly window resets %s\n' \
    "$BUDGET_BEFORE_WEEK" "$BUDGET_AFTER_WEEK" "$WEEK_DELTA" \
    "$BUDGET_BEFORE_SESSION" "$BUDGET_AFTER_SESSION" "${WEEK_RESET:-unknown}"
  printf 'Mode: %s / %s - %s - effort %s\n\n' "$MODE" "$TARGET" "$MODEL" "$EFFORT"
  printf -- '---\n\n'
  cat "$REPORT_FILE"
} >"$ISSUE_BODY"

ISSUE_URL="$(gh issue create \
  --title "Automated review — $STAMP ($TARGET)" \
  --body-file "$ISSUE_BODY" \
  --label review-report \
  --assignee @me 2>&1)"

RUN_OUTCOME="ok"
ISSUE_REF="$(printf '%s' "$ISSUE_URL" | grep -o '[0-9]*$' || true)"
FINDINGS_COUNT="$(grep -c '^### [0-9]' "$REPORT_FILE" || true)"
log "posted: $ISSUE_URL (${FINDINGS_COUNT} findings, ${SCANS_DONE} scan(s))"
