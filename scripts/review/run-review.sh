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
# Issues-only, no code: where security-tagged findings go instead of the public repo. See CLAUDE.md
# "Scheduled review job" for why.
SECURITY_REPO="Patrick9263/pickpic-security"
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
shift 2>/dev/null || true
DRY_RUN="no"
TARGET_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="yes"; shift ;;
    # Run one named area on demand, rather than whatever the weekday rotation would pick. The valid
    # names are the focus list at the top of prompts/daily.md.
    --target) TARGET_OVERRIDE="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$REPORTS_DIR" "$(dirname "$LOG_FILE")"

log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

# Invokes claude headlessly against $MODEL/$EFFORT/$ALLOWED, which callers set as globals before
# calling this. Defined this early so the surplus implement loop -- which runs well before the
# generic "Run" section further down -- can call it too.
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
ISSUE_REF_PRIVATE=""

record_metrics() {
  [[ "$DRY_RUN" == "yes" ]] && return 0
  if [[ ! -f "$METRICS_FILE" ]]; then
    printf 'timestamp,mode,kind,target,outcome,model,effort,scans,findings,week_before,week_after,week_delta,session_before,session_after,duration_s,issue,issue_private\n' >"$METRICS_FILE"
  fi
  local wb="${BUDGET_BEFORE_WEEK:-}" wa="${BUDGET_AFTER_WEEK:-}" wd=""
  [[ -n "$wb" && -n "$wa" && "$wa" != "?" ]] && wd=$(( wa - wb ))
  printf '%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$MODE" "${RUN_KIND:-}" "${TARGET:-}" "$RUN_OUTCOME" \
    "${MODEL:-}" "${EFFORT:-}" "$SCANS_DONE" "$FINDINGS_COUNT" \
    "$wb" "$wa" "$wd" "${BUDGET_BEFORE_SESSION:-}" "${BUDGET_AFTER_SESSION:-}" \
    "$(( $(date +%s) - START_EPOCH ))" "$ISSUE_REF" "$ISSUE_REF_PRIVATE" >>"$METRICS_FILE"
}

# Renders one row per recorded run for a numeric column of $METRICS_FILE, as a small ASCII gauge:
# date, a proportional bar, and the value -- rather than packing every run into a single line of
# Unicode block-height glyphs (▁▂▃▄▅▆▇█). Those eight glyphs differ by only a pixel or two at the
# font size a phone renders a GitHub issue at, and this report is explicitly meant to be read on one
# (see prompts/trends.md's opening line); a bar's *length* stays legible at any size, and plain "#"/
# "." characters hold a fixed width in every monospace font, which the box-drawing glyphs are not
# guaranteed to. Deterministic and network-free by design -- it never calls claude or gh, so it
# stays on the --dry-run path along with the rest of the trends decision (see MODE == trends below)
# instead of needing a live run to exercise.
#
# $1 is the column's 1-based CSV position (counting from the front, e.g. 11 for week_after) -- fixed
# from the front rather than the end because a live metrics.csv on disk can predate a later column
# being appended (issue_private was added after some rows were already written), and reading from
# the front is unaffected by that. $2 is the value's unit suffix (e.g. "%", or "" for a bare count).
# $3 is the scale to bar against, or 0 to scale against the largest value actually recorded: a
# percentage has a real, fixed 0-100 ceiling that must not be renormalized away, but an open-ended
# count (cost, findings) has no natural ceiling to fix in code. Blank fields (skip rows have no
# week_after/week_delta) are dropped, not plotted as zero.
#
# Every plotted row also carries week_before/week_after (columns 10/11) regardless of which column
# is being charted, purely to detect the weekly reset: when a run's week_before is lower than the
# previous plotted run's week_after, the budget window rolled over between them. Labelling that row
# matters because the weekly window is the x-axis every one of these columns moves against --
# unlabelled, a reset reads as the job's own cost collapsing rather than the week rolling over.
render_bar_chart() {
  local field="$1" unit="$2" fixed_max="$3"
  local -a ts=() vals=() is_reset=()
  local raw_ts wb wa v prev_after=""

  while IFS=',' read -r raw_ts wb wa v; do
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    if [[ -n "$prev_after" && "$wb" =~ ^[0-9]+$ && "$wb" -lt "$prev_after" ]]; then
      is_reset+=(1)
    else
      is_reset+=(0)
    fi
    ts+=("$raw_ts")
    vals+=("$v")
    [[ "$wa" =~ ^[0-9]+$ ]] && prev_after="$wa"
  done < <(tail -n +2 "$METRICS_FILE" | awk -F',' -v f="$field" '{print $1","$10","$11","$f}')

  if [[ ${#vals[@]} -eq 0 ]]; then
    printf '(no data yet)\n'
    return 0
  fi

  local scale_max="$fixed_max"
  if [[ "$scale_max" -eq 0 ]]; then
    scale_max=${vals[0]}
    for v in "${vals[@]}"; do
      [[ "$v" -gt "$scale_max" ]] && scale_max=$v
    done
  fi
  [[ "$scale_max" -eq 0 ]] && scale_max=1

  local width=15 i n=${#vals[@]} filled j bar date_part time_part note
  for (( i = 0; i < n; i++ )); do
    v="${vals[$i]}"
    filled=$(( v * width / scale_max ))
    [[ "$filled" -gt "$width" ]] && filled="$width"
    bar=""
    for (( j = 0; j < width; j++ )); do
      if [[ "$j" -lt "$filled" ]]; then
        bar+="#"
      else
        bar+="."
      fi
    done
    # ISO timestamps look like 2026-09-06T13:54:17-0400 -- chars 5..9 are MM-DD, 11..15 are HH:MM.
    date_part="${ts[$i]:5:5}"
    time_part="${ts[$i]:11:5}"
    note=""
    [[ "${is_reset[$i]}" -eq 1 ]] && note="  (week reset)"
    printf '%s %s  %s  %3d%s%s\n' "$date_part" "$time_part" "$bar" "$v" "$unit" "$note"
  done
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

  BUDGET_CHART="$(render_bar_chart 11 '%' 100)"  # week_after, fixed 0-100% scale
  COST_CHART="$(render_bar_chart 12 '' 0)"        # week_delta, scaled to its own observed max

  if [[ "$DRY_RUN" == "yes" ]]; then
    RUN_OUTCOME="dry-run"
    log "DRY RUN -- would post trends issue covering $METRIC_ROWS runs"
    log "weekly budget after each run:"
    log "$BUDGET_CHART"
    log "weekly cost per run:"
    log "$COST_CHART"
    exit 0
  fi

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
    # $BUDGET_CHART/$COST_CHART lose their trailing newline in command substitution, so the \n
    # before the closing fence has to be explicit -- without it the closing ``` lands glued to the
    # last data row instead of on its own line, and GitHub does not treat that as closing the fence.
    printf '**Weekly budget after each run** (oldest to newest)\n\n'
    printf "\`\`\`\n%s\n\`\`\`\n\n" "$BUDGET_CHART"
    printf '**Weekly cost per run, in points spent** (oldest to newest)\n\n'
    printf "\`\`\`\n%s\n\`\`\`\n\n" "$COST_CHART"
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

# Surplus mode prefers shipping already-triaged issues over generating more triage work. Every
# eligible `ready` issue is a candidate; how many actually get implemented this run is capped by the
# open-PR budget below, not by a fixed count -- it fires Friday and Saturday, so an empty PR queue on
# a Friday can clear most of a backlog in one run instead of trickling out one a week.
#
# `review-report` and `review-trends` issues are excluded even when labelled `ready`. Those are
# containers -- a report holds a numbered list of suggestions, not one implementable change -- and
# labelling one `ready` is an easy mistake to make while triaging on a phone. Picking one up makes
# the run implement several unrelated suggestions in one diff, which is exactly the unreviewable PR
# excluding them exists to prevent. (Each *issue* in the queue still becomes its own PR -- see below
# -- so this exclusion is unrelated to how many issues the run works through.)
#
# Oldest first, so the backlog drains in the order it was filed rather than newest-first, which is
# what `gh issue list` returns by default.
#
# Issues already covered by an open PR are skipped. An issue stays open until the PR closing it is
# merged, so without this the next run picks up the same issue it implemented yesterday and opens a
# duplicate PR against work already awaiting review.
READY_QUEUE=()
if [[ "$MODE" == "surplus" ]]; then
  LINKED_ISSUES="$(gh pr list --state open --limit 50 --json body --jq '.[].body // ""' 2>/dev/null \
    | grep -oiE '(closes|fixes|resolves) #[0-9]+' | grep -oE '[0-9]+' | sort -u || true)"
  for cand in $(gh issue list --label ready --state open --limit 50 --json number,labels \
      --jq '[.[] | select(([.labels[].name] | any(. == "review-report" or . == "review-trends")) | not)]
            | sort_by(.number) | .[].number' 2>/dev/null || true); do
    if printf '%s\n' "$LINKED_ISSUES" | grep -qx "$cand" 2>/dev/null; then
      log "skipping ready issue #$cand -- already has an open PR"
      continue
    fi
    READY_QUEUE+=("$cand")
  done
fi

# Unreviewed pull requests are backlog too, and the untriaged-issue count cannot see them.
#
# An implementation run produces a PR that needs real human review -- and for anything touching the
# UI or the iPad, browser or device verification that no unattended run can do. Left unchecked the
# job would keep opening them regardless of how many were already waiting. Six is deliberately
# generous: at the normal one-or-two-a-week rate it took three weeks of no review at all to reach, so
# it is a brake against genuine neglect rather than a throttle on ordinary use. Trim the queue to
# however many slots remain under that ceiling rather than an all-or-nothing gate, so a backlog of
# ready issues drains as fast as review capacity allows instead of one per run.
if [[ ${#READY_QUEUE[@]} -gt 0 ]]; then
  OPEN_PRS="$(gh pr list --state open --limit 50 --json number --jq 'length' 2>/dev/null || echo 0)"
  SLOTS=$(( 6 - OPEN_PRS ))
  if [[ "$SLOTS" -le 0 ]]; then
    log "skipping implement: $OPEN_PRS open PRs already awaiting review"
    READY_QUEUE=()
  elif [[ "$SLOTS" -lt "${#READY_QUEUE[@]}" ]]; then
    log "trimming ready queue to $SLOTS issue(s) -- $OPEN_PRS open PRs already awaiting review"
    READY_QUEUE=("${READY_QUEUE[@]:0:$SLOTS}")
  fi
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
if [[ ${#READY_QUEUE[@]} -eq 0 && "$UNTRIAGED" -gt 15 ]]; then
  RUN_OUTCOME="skip-backlog-full"
  log "SKIP: $UNTRIAGED untriaged open issues already -- not adding more"
  exit 0
fi

# Implement every issue in the queue, one PR each, until the queue is empty, budget runs low, or a PR
# this run itself opened brings the open-PR count back up to the ceiling. This is a self-contained
# path with its own exit: it never falls through to the sweep/analysis logic below, which only
# applies when there was nothing ready to implement.
if [[ ${#READY_QUEUE[@]} -gt 0 ]]; then
  RUN_KIND="implement"
  PROMPT_FILE="$REPO/scripts/review/prompts/surplus.md"
  TARGET="issues ${READY_QUEUE[*]}"
  log "kind=implement queue=${READY_QUEUE[*]} model=${MODEL} effort=${EFFORT}"

  if [[ "$DRY_RUN" == "yes" ]]; then
    RUN_OUTCOME="dry-run"
    log "DRY RUN -- would implement ready issues: ${READY_QUEUE[*]}"
    exit 0
  fi

  # Xcode overwrites a disk-edited project.pbxproj from its stale in-memory copy and silently drops
  # file references (CLAUDE.md trap 4). An unattended run must never risk that. Computed once and
  # reused for every issue in the queue since Xcode's running state won't change mid-run.
  XCODE_NOTE=""
  if pgrep -x Xcode >/dev/null 2>&1; then
    XCODE_NOTE="

IMPORTANT: Xcode is currently running on this machine. You must NOT edit ipad/PickPic.xcodeproj/project.pbxproj.
If this issue requires adding a new Swift file, stop and report that it was deferred for that reason."
  fi

  # An array, not a space-separated string: several of these rules contain spaces inside the
  # parentheses, and an unquoted string expansion splits them into fragments the CLI then rejects.
  ALLOWED=(Read Grep Glob Edit Write "Bash(git:*)" "Bash(gh:*)" "Bash(npm:*)" "Bash(xcodebuild:*)")

  STAMP="$(date +%Y-%m-%d)"
  IMPLEMENTED_ISSUES=()
  OPENED_PRS=()
  # One entry per issue attempted, "$issue:$pr" or "$issue:no-pr" or "$issue:failed" -- the trends
  # audit found implement-pass yield was under-logged (issues #129/#145 showed no PR and no way to
  # tell whether the pass failed or just went unrecorded). This makes every attempt explicit instead
  # of only listing the PRs that happened to land.
  ISSUE_OUTCOMES=()

  for issue in "${READY_QUEUE[@]}"; do
    # A PR opened earlier in this same loop counts against the ceiling exactly like one left over
    # from a previous run -- re-check rather than trusting the count computed before the loop started.
    OPEN_PRS="$(gh pr list --state open --limit 50 --json number --jq 'length' 2>/dev/null || echo 0)"
    if [[ "$OPEN_PRS" -ge 6 ]]; then
      log "stopping implement loop before issue #$issue: $OPEN_PRS open PRs already awaiting review"
      break
    fi

    # Re-check budget between issues, same reasoning as the sweep loop below: implementing several
    # issues can be the longest thing this job does, and an interactive session can move the window
    # underneath it while it runs.
    read_usage
    if [[ -n "${WEEK_PCT:-}" && "$WEEK_PCT" -ge 70 ]]; then
      log "implement: stopping early at ${WEEK_PCT}% weekly, before issue #$issue"
      break
    fi

    # Fetched here, not left for the model to fetch: `gh` cannot be granted to a headless run (see
    # the "Two things about headless claude -p" note below), so a prompt that told the model to run
    # `gh issue view` itself stalled on an unanswerable approval prompt roughly half the time. Built
    # by string concatenation rather than a sed substitution -- an issue body can contain `|`,
    # backslashes, or newlines that a sed replacement pattern would choke on.
    ISSUE_BLOCK="$(gh issue view "$issue" --json title,body,labels \
      --jq '"**Title:** " + .title + "\n**Labels:** " + ([.labels[].name] | join(", ")) + "\n\n" + (.body // "(no body)")' \
      2>/dev/null || true)"
    if [[ -z "$ISSUE_BLOCK" ]]; then
      log "implement: could not fetch issue #$issue from GitHub -- skipping"
      continue
    fi

    ISSUE_PROMPT="$(sed -e "s|{{TARGET}}|issue #$issue|g" -e "s|{{ISSUE}}|$issue|g" "$PROMPT_FILE")

## Issue #$issue content

$ISSUE_BLOCK
$XCODE_NOTE"
    PR_BEFORE="$(gh pr list --state open --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null || true)"

    log "implement: issue #$issue"
    if ! run_claude "$ISSUE_PROMPT" "$REPORTS_DIR/$STAMP-implement-$issue.md"; then
      log "implement: issue #$issue failed, continuing to the next"
      ISSUE_OUTCOMES+=("$issue:failed")
      continue
    fi
    SCANS_DONE=$(( SCANS_DONE + 1 ))
    IMPLEMENTED_ISSUES+=("$issue")

    # The wrapper does not open the PR -- the model does, as part of the prompt -- so the only way to
    # know one landed is to look for one that was not there before.
    PR_AFTER="$(gh pr list --state open --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    if [[ -n "$PR_AFTER" && "$PR_AFTER" != "$PR_BEFORE" ]]; then
      OPENED_PRS+=("$PR_AFTER")
      ISSUE_OUTCOMES+=("$issue:$PR_AFTER")
      log "opened PR #$PR_AFTER for issue #$issue"
    else
      ISSUE_OUTCOMES+=("$issue:no-pr")
      log "no new PR detected for issue #$issue -- the run may have stopped short; check $REPORTS_DIR/$STAMP-implement-$issue.md"
    fi

    # Each issue's prompt starts with `git checkout main && git pull`, so this is a safety net rather
    # than the only thing putting the tree back -- but it also refuses on a dirty tree (uncommitted
    # work is worth more than the convenience), which is exactly the state a failed or half-finished
    # issue could leave behind before the next one starts.
    restore_branch
  done

  read_usage
  BUDGET_AFTER_WEEK="${WEEK_PCT:-?}"
  BUDGET_AFTER_SESSION="${SESSION_PCT:-?}"
  # Semicolon-joined, not comma-joined: ISSUE_REF lands in an unquoted field of the metrics CSV
  # below, and a comma there would be read back as an extra column. Per-issue outcomes (not just the
  # PRs that landed) so a future trends audit can see every attempt, not only the successful ones.
  ISSUE_REF="$(IFS=';'; echo "${ISSUE_OUTCOMES[*]:-}")"
  RUN_OUTCOME="ok-implement"
  log "implement loop finished: ${#IMPLEMENTED_ISSUES[@]}/${#READY_QUEUE[@]} issue(s) implemented, PRs: ${OPENED_PRS[*]:-none}"
  exit 0
fi

if [[ "$MODE" == "surplus" ]]; then
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
  TARGET="${TARGET_OVERRIDE:-$(rotation_target)}"
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

PROMPT="$(sed -e "s|{{TARGET}}|$TARGET|g" -e "s|{{ISSUE}}||g" "$PROMPT_FILE")"

# Deduplication context, gathered here rather than by the model. The wrapper runs in an ordinary
# shell where `gh` works; an analysis run does not (see the ALLOWED note below), and without this a
# report happily re-proposes things already filed or already declined.
#
# RUN_KIND is always "sweep" or "analyse" by this point -- "implement" is handled entirely above,
# in its own self-contained loop that exits before reaching here.
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

# Analysis gets no Bash at all. `gh` cannot be granted to a headless `-p` run through
# --allowedTools -- it asks for approval regardless of the rule, and in print mode there is nobody
# to approve it -- so the wrapper gathers the git and GitHub context itself (just above) and hands
# it over in the prompt. That also keeps the analysis run genuinely read-only.
ALLOWED=(Read Grep Glob)

# Splits a finished report into a public and a private file by each finding's **Category** tag,
# so a security-flavored finding never reaches the public gh issue create below. A report with no
# numbered findings at all (the honest "nothing found" case the prompt explicitly allows) is passed
# through to the public file untouched -- there is nothing to route privately.
split_by_category() {
  local infile="$1" pubfile="$2" privfile="$3"
  : >"$pubfile"
  : >"$privfile"
  if ! grep -q '^### [0-9]' "$infile" 2>/dev/null; then
    cat "$infile" >"$pubfile"
    return 0
  fi
  awk -v pub="$pubfile" -v priv="$privfile" '
    /^### [0-9]+\./ {
      if (have_block) print block > (is_security ? priv : pub)
      block = $0 "\n"; is_security = 0; have_block = 1
      next
    }
    have_block {
      block = block $0 "\n"
      if (tolower($0) ~ /\*\*category\*\*.*security/) is_security = 1
    }
    END { if (have_block) print block > (is_security ? priv : pub) }
  ' "$infile"
}

# Findings are numbered within their original (pre-split) report, so each bucket needs its own
# 1..N sequence afterward.
renumber() {
  local file="$1"
  [[ -s "$file" ]] || return 0
  awk '
    /^### [0-9]+\./ { n++; sub(/^### [0-9]+\./, "### " n "."); print; next }
    { print }
  ' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}

if [[ "$RUN_KIND" == "sweep" ]]; then
  SWEEP_ACCUM="$STATE_DIR/.sweep-findings.md"
  PRIVATE_ACCUM="$STATE_DIR/.sweep-findings-private.md"
  : >"$SWEEP_ACCUM"
  : >"$PRIVATE_ACCUM"

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
    if [[ -s "$SWEEP_ACCUM" || -s "$PRIVATE_ACCUM" ]]; then
      SCAN_PROMPT="$SCAN_PROMPT

## Already found earlier in this same sweep — do not repeat any of these

$(cat "$SWEEP_ACCUM" "$PRIVATE_ACCUM" 2>/dev/null)"
    fi

    log "sweep: scanning $t"
    if run_claude "$SCAN_PROMPT" "$REPORTS_DIR/$STAMP-sweep-$t.md"; then
      SCANS_DONE=$(( SCANS_DONE + 1 ))
      # security and worker-auth-and-tenancy are security scans by definition -- route the whole
      # sub-report privately rather than trusting per-finding **Category** tagging for these two.
      if [[ "$t" == "security" || "$t" == "worker-auth-and-tenancy" ]]; then
        printf '\n## From the %s scan\n\n' "$t" >>"$PRIVATE_ACCUM"
        cat "$REPORTS_DIR/$STAMP-sweep-$t.md" >>"$PRIVATE_ACCUM"
      else
        printf '\n## From the %s scan\n\n' "$t" >>"$SWEEP_ACCUM"
        cat "$REPORTS_DIR/$STAMP-sweep-$t.md" >>"$SWEEP_ACCUM"
      fi
    else
      log "sweep: $t scan failed, continuing"
    fi
  done

  if [[ ! -s "$SWEEP_ACCUM" && ! -s "$PRIVATE_ACCUM" ]]; then
    RUN_OUTCOME="error-no-findings"
    log "ERROR: sweep produced no findings"
    exit 1
  fi

  # Consolidate the public findings only. The private accumulator (the two security-named scans,
  # plus whatever else gets **Category** — security tagged below) is short enough -- usually one or
  # two scans' worth -- that it doesn't need ranking down to a slot cap; it's posted close to as-is.
  if [[ -s "$SWEEP_ACCUM" ]]; then
    log "sweep: consolidating"
    CONSOLIDATE_PROMPT="Below are findings from several independent scans of the PickPic codebase,
each covering a different area. Merge them into ONE ranked report.

Rules:
- Combine duplicates and near-duplicates into a single entry, keeping the clearest wording.
- Drop anything trivial or speculative. Quality over completeness.
- Keep at most $BACKLOG_DEFICIT entries. If there are more, keep the best ones. Do not pad to reach
  that number — a shorter honest report is better than a padded one.
- Renumber from 1, ordered by value, most worth doing first.
- Preserve each entry's What / Why it matters / Where / Size / Category structure verbatim where
  you can. Category in particular must never be dropped or invented -- it decides whether the
  finding is published or routed privately.
- Output only the merged markdown report. No preamble, no commentary about merging.
- End with a single line '**Recommended next:**' naming the one entry to do first and why.

$(cat "$SWEEP_ACCUM")"

    if ! run_claude "$CONSOLIDATE_PROMPT" "$REPORT_FILE"; then
      log "consolidation failed -- falling back to the raw concatenated findings"
      cp "$SWEEP_ACCUM" "$REPORT_FILE"
    fi
  else
    : >"$REPORT_FILE"
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
# RUN_KIND is always "sweep" or "analyse" here -- "implement" opens its own PR(s) and exits from its
# own loop above, with nothing further to post.

# Split by **Category** before anything gets posted -- this is the only gate between a described,
# unfixed vulnerability and the public issue tracker. See CLAUDE.md "Scheduled review job".
PUBLIC_REPORT="$REPORT_FILE.public.md"
PRIVATE_REPORT="$REPORT_FILE.private.md"
split_by_category "$REPORT_FILE" "$PUBLIC_REPORT" "$PRIVATE_REPORT"

# Sweep's security-named scans bypassed tagging entirely (see the loop above) -- fold their raw,
# unconsolidated findings into the private report too.
if [[ "$RUN_KIND" == "sweep" && -s "${PRIVATE_ACCUM:-}" ]]; then
  cat "$PRIVATE_ACCUM" >>"$PRIVATE_REPORT"
fi

renumber "$PUBLIC_REPORT"
renumber "$PRIVATE_REPORT"

RUN_OUTCOME="ok"
FINDINGS_COUNT=$(( $(grep -c '^### [0-9]' "$PUBLIC_REPORT" 2>/dev/null || echo 0) \
  + $(grep -c '^### [0-9]' "$PRIVATE_REPORT" 2>/dev/null || echo 0) ))

if [[ -s "$PUBLIC_REPORT" ]]; then
  ISSUE_BODY="$STATE_DIR/.issue-body.md"
  {
    printf 'Budget: weekly %s%% -> %s%% used (+%s pts) - session %s%% -> %s%% - weekly window resets %s\n' \
      "$BUDGET_BEFORE_WEEK" "$BUDGET_AFTER_WEEK" "$WEEK_DELTA" \
      "$BUDGET_BEFORE_SESSION" "$BUDGET_AFTER_SESSION" "${WEEK_RESET:-unknown}"
    printf 'Mode: %s / %s - %s - effort %s\n\n' "$MODE" "$TARGET" "$MODEL" "$EFFORT"
    printf -- '---\n\n'
    cat "$PUBLIC_REPORT"
  } >"$ISSUE_BODY"

  ISSUE_URL="$(gh issue create \
    --title "Automated review — $STAMP ($TARGET)" \
    --body-file "$ISSUE_BODY" \
    --label review-report \
    --assignee @me 2>&1)"
  ISSUE_REF="$(printf '%s' "$ISSUE_URL" | grep -o '[0-9]*$' || true)"
  log "posted: $ISSUE_URL"

  # The trends audit's biggest blind spot: conversion (findings -> filed issues) has to be inferred
  # from timing and topic alone, because nothing links a filed issue back to the suggestion it came
  # from. The issue number is only known after creation, so this is a follow-up comment rather than
  # part of the body.
  if [[ -n "$ISSUE_REF" ]]; then
    gh issue comment "$ISSUE_REF" \
      --body "When filing an issue for one of the findings above, reference this report (e.g. \"from #$ISSUE_REF (3)\") so next Sunday's trends audit can count conversion directly instead of inferring it from timing." \
      >/dev/null 2>&1 || true
  fi
else
  log "nothing public this run -- all findings were security-tagged"
fi

# Security-tagged findings never reach the public repo -- they go to a private, code-free companion
# repo instead, so Patrick still sees them but a description of an unfixed hole is never public.
if [[ -s "$PRIVATE_REPORT" ]]; then
  PRIVATE_ISSUE_BODY="$STATE_DIR/.issue-body-private.md"
  {
    printf 'Budget: weekly %s%% -> %s%% used (+%s pts) - session %s%% -> %s%% - weekly window resets %s\n' \
      "$BUDGET_BEFORE_WEEK" "$BUDGET_AFTER_WEEK" "$WEEK_DELTA" \
      "$BUDGET_BEFORE_SESSION" "$BUDGET_AFTER_SESSION" "${WEEK_RESET:-unknown}"
    printf 'Mode: %s / %s - %s - effort %s\n\n' "$MODE" "$TARGET" "$MODEL" "$EFFORT"
    printf -- '---\n\n'
    cat "$PRIVATE_REPORT"
  } >"$PRIVATE_ISSUE_BODY"

  PRIVATE_ISSUE_URL="$(gh issue create \
    --repo "$SECURITY_REPO" \
    --title "Automated review — $STAMP ($TARGET)" \
    --body-file "$PRIVATE_ISSUE_BODY" \
    --label review-report \
    --assignee @me 2>&1)"
  ISSUE_REF_PRIVATE="$(printf '%s' "$PRIVATE_ISSUE_URL" | grep -o '[0-9]*$' || true)"
  log "posted (private): $PRIVATE_ISSUE_URL"

  if [[ -n "$ISSUE_REF_PRIVATE" ]]; then
    gh issue comment "$ISSUE_REF_PRIVATE" --repo "$SECURITY_REPO" \
      --body "When filing an issue for one of the findings above, reference this report (e.g. \"from #$ISSUE_REF_PRIVATE (2)\") so next Sunday's trends audit can count conversion directly instead of inferring it from timing." \
      >/dev/null 2>&1 || true
  fi
fi

log "findings: ${FINDINGS_COUNT} total (${SCANS_DONE} scan(s))"
