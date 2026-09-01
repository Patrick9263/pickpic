# Pricing, lifecycle, and notifications

Status: a proposal, not a shipped plan. Nothing in this document is implemented.
Every price and limit here is a starting point, and the section at the end lists
what is still genuinely open.

This assumes PickPic becomes a product other photographers pay for. The rest of
the repository still describes it as a private tool; migrations 0013-0015 and the
`app.pickpic.photos` deployment point the other way. That question is not settled
here.

## The cost shape this is built on

PickPic pushes almost all compute to clients. RAW to JPEG conversion happens on
the iPad, thumbnails and previews are generated in the browser
([src/imageVariants.ts](../src/imageVariants.ts)), and ZIP archives are built in
the viewer's browser. R2 charges nothing for egress.

So serving a gallery costs approximately nothing, and the only meaningful
marginal cost is **bytes multiplied by time**, at roughly $0.015 per GB-month. A
500-photo event with 50 finals is on the order of 2.5 GB, or about four cents a
month.

Infrastructure is therefore not a useful input to the price. Storage limits in
this document exist as fences against runaway accounts, not as the thing being
sold.

## Who pays

Photographers pay. Viewers never do.

Hearting is the core loop, and it works because a viewer needs no account -- they
are identified by a cookie, and the mutation routes are guarded by
`requireOpenGallery`. Any signup requirement on the viewer side would destroy the
product.

## What is being sold

A delivered gallery, plus the time it stays available. Not photos, and not
gigabytes.

Gigabytes are a unit photographers cannot estimate -- nobody knows whether a
wedding is 2 GB or 20 -- and pricing in that unit invites comparison against
commodity storage that will always be cheaper.

## Tiers

|                  | Free / Beta      | Solo $15/mo | Studio $39/mo |
| ---------------- | ---------------- | ----------- | ------------- |
| Active galleries | 1                | 3           | unlimited     |
| Photos per event | ~100             | unlimited   | unlimited     |
| Included storage | 2 GB, a hard cap | 250 GB      | 1 TB          |
| Over the cap     | uploads blocked  | $0.50/GB-mo | $0.50/GB-mo   |
| Retention        | 30 days          | 1 year      | indefinite    |
| Account users    | 1                | 1           | multiple      |
| iPad RAW app     | not included     | included    | included      |

Multiple users per account needs no schema work: `account_users.role` already
exists and 0013 deliberately left it without a CHECK constraint so a second role
can be added freely.

The iPad app is the paid tier's differentiator. Durable RAW ingest with an
on-device queue that survives suspension is the part of PickPic that is hard to
copy, and giving it away spends the advantage.

### The free tier blocks; the paid tiers meter

This distinction matters more than the numbers. A paid account has a card on
file, so billing for overage works. A free account does not, so overage there is
uncollectable. The free ceiling must therefore **refuse the upload** with a clear
"upgrade or delete a gallery" message. It must never produce a surprise bill and
never silently drop photos.

2 GB is roughly three times what the 100-photo limit actually produces, so no
legitimate free user will reach it.

The stronger protection is structural rather than numeric: free carries 30-day
retention, so free storage never accumulates. Steady-state cost is the number of
active free users multiplied by roughly 0.6 GB, not a figure that grows forever.
Ten thousand simultaneously saturated free accounts would be about 20 TB, or
roughly $300 a month, and reality will be far below that.

Free doubles as the beta tier. The beta terms should say plainly that limits
tighten at general availability, so that tightening them later reads as expected
rather than as a betrayal.

### Paid overage is a guardrail, not a revenue line

$0.50 per GB-month is roughly thirty times cost. It is priced so that nobody
chooses it. Its only job is to stop a single account storing a terabyte on a $15
plan.

The included caps are sized so that even a customer sitting exactly at the
ceiling is profitable: 250 GB costs about $3.75 against $15 of revenue, and 1 TB
about $15 against $39.

In the interface, retention should be the limit users see and think about. The
gigabyte meter belongs in the background.

## The single event pass

Roughly $9, sold as a credit rather than as an immediately-starting window.

| Phase                             | State                                                |
| --------------------------------- | ---------------------------------------------------- |
| Purchase                          | A credit sits on the account. No clock runs.         |
| Applied at publish, then +90 days | Live: hearts, comments, finals, downloads            |
| +90 to +180 days                  | Read-only. Downloads still work. Reminders are sent. |
| +180 days                         | R2 objects purged. Event row and metadata retained.  |

Two things make this work.

**The clock starts at publish, not at purchase.** A postponed wedding, or a
photographer who shoots in June and uploads in July, should not burn a window
they never used. Purchasing a credit that is applied later also makes 3-packs and
10-packs possible, which is the most promising revenue idea in the pass model.

**The window ends in deletion, not in a closed gallery.** A pass is a one-time
payment against a recurring cost. If expiry only takes the gallery offline, a
single $9 payment buys perpetual storage rent. Purging at day 180 fixes the
liability at roughly $0.23 of storage per pass, which is a number the business
can plan around.

A +90-day extension at around $4 should exist, but the real purpose of expiry is
conversion. A photographer looking at galleries about to purge is the easiest
subscription sale available.

Deleting is defensible here in a way it would not be for a general storage
product. [CLAUDE.md](../CLAUDE.md) states the principle directly: originals stay
local, and the cloud is never the source of truth for photos. Purging an expired
gallery removes a delivery copy of files the photographer still holds.

## Expiry is a timestamp, not a status

There must be no `closed` event status.

[migrations/0001_create_events.sql](../migrations/0001_create_events.sql) placed a
six-value CHECK constraint on `events.status`, and that constraint is still on the
table. 0012 did not replace it; it narrowed the effective set to four values with
BEFORE INSERT and BEFORE UPDATE triggers layered on top. `'closed'` is not among
the six, so adding it means altering the CHECK, which SQLite can only do by
rebuilding `events`. That rebuild fires the `ON DELETE CASCADE` edges from
`photos`, `gallery_visitors` and `event_notifications` -- precisely the operation
0012 documents at length as having destroyed every child row when it was tested.

The model is a nullable `expires_at` column on `events`, which is an
`ALTER TABLE ADD COLUMN` and therefore the cheap, non-destructive operation that
0013's comments explicitly favour, combined with the existing `completed` and
`archived` statuses and a scheduled job that acts on the date.

Expiry is a deadline rather than a state in any case. The exact timestamp is
needed for interface countdowns and for reminder emails regardless, and once it
is stored a separate status carries no additional information.

For the record, `'uploading'` and `'editing'` still satisfy the original CHECK and
are blocked only by 0012's triggers, making them the only status values that could
be added without a rebuild. Both are semantically wrong for expiry, and #101
removed them deliberately.

## Notifications

Notifications are a prerequisite of the lifecycle above, not a feature alongside
it. A gallery cannot be purged on day 180 without its owner having been warned,
so the event pass cannot ship until a delivery channel exists.

Users choose email, in-app, or both, per notification type.

Half the plumbing is already built. `event_notifications` (0011) is a real queue
with retry and backoff, and [worker/email.ts](../worker/email.ts) already sends
through Resend for magic links, so email requires no new vendor.

"App notifications" covers two separate things, both worth building, in this
order:

1. **An in-app feed** in the dashboard and the iPad app, reading the same queue.
   No new infrastructure.
2. **Push.** APNs for the iPad, needing a device-token table and an APNs key; Web
   Push for browsers, needing VAPID and a subscription table. APNs comes first --
   the iPad is where push actually earns its place.

Telegram ([worker/telegram.ts](../worker/telegram.ts)) remains as a third channel,
in practice an internal one.

### The schema constraint to design around

`event_notifications` has the primary key `(event_id, notification_type)`, one row
per type per event, so it structurally cannot represent one notification delivered
over two channels. It also carries a CHECK on `status`, which 0013's comments
already single out as the cautionary example of a constraint that cannot gain a
new value without a table rebuild.

So do not rebuild it. Add a new `notification_deliveries` table with the channel
in its key, and a `notification_preferences` table keyed on
`(account_user_id, notification_type)` with one boolean per channel, email
defaulting to on. Both are plain `CREATE TABLE` statements, which keeps this
inside the rule 0012 and 0013 established.

### Notification types the plan requires

Gallery expiring in 14 days; gallery expiring in 24 hours; gallery now read-only;
gallery purged; payment failed or account past due. These join the existing
upload-started notification.

## What has to be built first

None of this exists today.

1. **Metering, cheap enough for the upload path.** `collectEventStorageKeys`
   gathers keys for deletion only; nothing measures account usage. All three write
   paths need the cap check: `createPhoto`, `uploadFinalPhoto` and
   `uploadPhotoVariants` in [worker/index.ts](../worker/index.ts). A
   `SUM(byte_size)` per upload is too expensive on D1, so maintain an
   `accounts.storage_bytes` counter, incremented on upload and decremented on
   delete and purge, with a periodic reconciliation job against the true sum. The
   rollup query is the auditor, not the enforcer. The indexes this needs already
   exist: `events_account_id_created_at_idx` and `photos_account_id_event_id_idx`
   were laid out in 0013 for exactly this.
2. **`expires_at` on `events`.**
3. **Entitlements as per-account columns rather than constants**, so a beta
   tester's cap can be raised without a deployment, enforced in
   `resolveAccountForPrincipal` so that every admin route inherits the check.
4. **A `past_due` value for `accounts.status`.** Free to add: 0013 deliberately
   left that column without a CHECK constraint, naming this exact case.
5. **Stripe Checkout, the customer portal, and a webhook route** in the worker's
   ordered regex chain. Store only the customer id, subscription id, plan, and
   period end.
6. **A Cron Trigger.** `wrangler.jsonc` declares none today. It drives expiry,
   purging, and draining the notification queue.
7. **A real purge step.** `archived` is currently only a status change; R2 deletes
   happen solely on explicit deletion. An archived gallery costs exactly as much
   as a live one.
8. **`notification_deliveries` and `notification_preferences`**, an APNs sender,
   and preference interfaces in both the dashboard and the iPad app.

## Still open

- **Whether PickPic is a product at all**, or stays a private tool. Everything
  above assumes the former.
- **Every price point is a proposal.** No market research stands behind them.
- **2.5 GB per event is an estimate, not a measurement.** Every storage cap in
  this document derives from it, which is a good reason to build metering first
  and set the caps from real data.
- **Web Push in v1, or APNs only.**
- **Throwaway free accounts.** The per-account caps bound what one greedy account
  can do, not what many accounts can. Magic-link signup makes many accounts easy.
  Not worth solving at beta scale, but it is a known gap rather than a solved
  problem.
