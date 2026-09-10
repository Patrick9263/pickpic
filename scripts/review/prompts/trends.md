You are auditing the PickPic scheduled review job against its own results. Your output becomes a
GitHub issue Patrick reads on his phone.

This is not a code review. The subject is the job itself: whether its thresholds are set correctly,
and whether it is producing work worth the budget it spends. The data is appended below — the
metrics CSV it writes on every run, and every issue in the repository.

Two things about reading that CSV. Rows written before the `implemented` column existed simply end
early — count columns from the front, not the back. And the backlog figure the job gates on changed
meaning: it used to count every unlabelled open issue, which swept in Patrick's hand-written feature
backlog and stood the weekday runs down for reasons that had nothing to do with this job; it now
counts only findings still unread inside open `review-report` issues. Older `skip-backlog-full` rows
were therefore produced under a stricter, differently-shaped rule than current ones — do not read a
trend across that boundary without saying so.

## The question that matters most

**Conversion: what fraction of suggestions actually became issues Patrick filed?**

Cost is already understood — roughly one point of the weekly window per scan — and is not the
binding constraint. Attention is. So the signal to hunt for is whether the suggestions produced are
being taken up:

- Reports are posted as issues labelled `review-report`, each containing numbered suggestions.
- When Patrick acts on one, he files a separate issue for it (usually labelled `enhancement` or
  `bug`) shortly afterwards, and eventually closes the report.
- So new non-report issues appearing after a report is a reasonable proxy for conversion, and a
  report left open for a long time is a sign the output outran his capacity to read it.

**Low conversion means the caps are too generous** and scans are being wasted producing suggestions
nobody wants. **High conversion means the caps are throttling** work that would have been useful.

## What to report

1. **Conversion rate**, as best the data supports, with the reasoning shown. Say plainly if the data
   cannot support the estimate.
2. **Cost per run and per finding**, and whether either is trending up or down.
3. **Skip behaviour** — how often the job stood down, and which `outcome` values dominate. A run of
   `skip-weekly-ceiling` means the thresholds are mis-set; a run of `skip-backlog-full` means the
   backlog target is below what Patrick actually clears.
4. **Depth labels and deferrals.** Issues now declare the model and effort they deserve through
   `model:` / `effort:` labels, and the budget ladder treats that as a ceiling — an issue asking for
   more than a morning affords is deferred rather than downgraded. The `implemented` column records
   one entry per attempt: `<issue>:<pr>:<model>/<effort>`, `<issue>:no-pr:...`, `<issue>:failed:...`,
   or `<issue>:deferred-budget`. Report:
   - **Starvation.** Any issue number that appears as `deferred-budget` repeatedly and **never**
     alongside a PR is stuck: it is asking for a depth this job's budget never reaches. Name those
     issues explicitly and say what depth they are asking for. This is the failure mode with no other
     alarm on it — the issue simply never gets done, quietly.
   - Whether the depth each issue ran at looks right in hindsight, using the PR descriptions (an
     implementing run is told to flag a mis-sized issue in one line) — are the labels too generous,
     too mean, or about right?
   - How often a run filled its weight budget, which would mean work is queueing behind the cap.
5. **Concrete threshold recommendations**, or an explicit statement that none is warranted yet. The
   settings currently in `scripts/review/run-review.sh` that you may recommend changing:
   - the backlog targets (12 / 8 / 5, chosen by weekly headroom). **These were recalibrated from
     24/15/9 on a single week's data** when the backlog metric was narrowed to unread findings only,
     so they are the least-evidenced numbers here and the ones most worth revisiting first.
   - the assumed three surviving findings per scan, which converts a backlog deficit into a scan count
   - the depth ladder boundaries (45% / 65% / 80% weekly)
   - the surplus gate (weekly < 60%), the mid-sweep stop (70%), and the weekday implement gate (70%)
   - the weight budgets a single run may spend on implementation (4 on a weekday, 10 on surplus)
   - the follow-on analysis gates — after implementing, a run also analyses only when the session is
     under 50%, unread findings are at most 15, and fewer than 6 PRs are open
   - the 15-unread-finding ceiling

## Be honest about how little data there is

The job produces only a handful of runs a week. **With fewer than about three weeks of data, do not
recommend threshold changes** — say that plainly instead, and name what you would want to see before
recommending one. A confident recommendation drawn from six rows is worse than no recommendation,
because it will be acted on.

Label every claim with the number of runs behind it. Where a trend is one or two data points, call
it an observation rather than a trend.

## Output format

Output only markdown. No preamble. Keep it short — this is a status readout, not an essay.

Use a brief summary line, then a small table of the key figures, then at most five observations, then
your recommendations (or the statement that none is warranted). End with a single line
`**Verdict:**` saying whether the job is currently worth what it costs.
