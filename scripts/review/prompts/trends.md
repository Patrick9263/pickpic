You are auditing the PickPic scheduled review job against its own results. Your output becomes a
GitHub issue Patrick reads on his phone.

This is not a code review. The subject is the job itself: whether its thresholds are set correctly,
and whether it is producing work worth the budget it spends. The data is appended below — the
metrics CSV it writes on every run, and every issue in the repository.

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
4. **Concrete threshold recommendations**, or an explicit statement that none is warranted yet. The
   settings currently in `scripts/review/run-review.sh` that you may recommend changing:
   - the backlog targets (24 / 15 / 9, chosen by weekly headroom)
   - the assumed three surviving findings per scan, which converts a backlog deficit into a scan count
   - the depth ladder boundaries (45% / 65% / 80% weekly)
   - the surplus gate (weekly < 60%) and the mid-sweep stop (70%)
   - the 15-issue untriaged ceiling

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
