# Signing the iPad in to PickPic

Since #188 the iPad app authenticates with a per-account session against
`app.pickpic.photos` instead of the shared Cloudflare Access service token. This
is the one-time setup and the recurring routine.

## One-time: check which account your sign-in reaches

Every event and photo that existed before migration 0013 was backfilled to the
**bootstrap account**, `00000000-0000-4000-8000-000000000001`. Cloudflare Access
resolves to that account without an `account_users` row, so the operator reached
it for a long time without one existing.

A session is different: it is only ever as good as the `account_users` row behind
it, and the iPad sees exactly the events of the account that row names. So the
question to settle before the first sign-in is not whether a row exists — one
usually does by now, created by signing in to the web app — but whether the row
for your address points at the account that owns your photos:

```bash
npx wrangler d1 execute pickpic-db --remote --command "
SELECT u.email, u.auth_provider, u.role, u.account_id, a.name,
       (SELECT COUNT(*) FROM events e WHERE e.account_id = u.account_id) AS events
FROM account_users u
JOIN accounts a ON a.id = u.account_id
ORDER BY events DESC, u.email;"
```

Two normal results are worth recognising. **Two rows for one address, one
`email` and one `apple`, are the same person** — Sign in with Apple attaches a
second row against the same account rather than replacing the first. And an
address you do not recognise may be an Apple Hide-My-Email relay from a past web
sign-in; it is still a full identity on whatever account it names, so treat an
unexpected `owner` row as something to account for rather than ignore.

The failure to look for is your address naming an account with `events = 0`
while your photos sit under the bootstrap account. That happens if the row was
created by **signing up through `/sign-up`, which makes a new, empty account** —
the iPad would sign in successfully and show nothing. Repoint the row rather
than signing up again.

If no row exists for your address at all, create one:

```sql
INSERT INTO account_users (
  id,
  account_id,
  auth_provider,
  auth_subject,
  email,
  role,
  created_at,
  updated_at
)
VALUES (
  lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' ||
    substr(lower(hex(randomblob(2))), 2) || '-a' ||
    substr(lower(hex(randomblob(2))), 2) || '-' || lower(hex(randomblob(6))),
  '00000000-0000-4000-8000-000000000001',
  'email',
  'you@example.com',
  'you@example.com',
  'owner',
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);
```

Three details are load-bearing:

- **`auth_provider` must be `email` and `auth_subject` must be the address,
  lowercased.** `requestMagicLink` looks the user up by exactly that pair, and
  addresses are normalised to lowercase before the lookup. A row that disagrees
  produces no error — the endpoint answers `ok` for an unknown address by
  design, so the symptom is simply that no email ever arrives.
- **`role` must be `owner`.** `requireOwnerRole` gates deleting an event,
  clearing an event's photos, and clearing a photo's hearts. Any other role can
  upload but cannot delete.
- This is **not** a migration. It names a personal email address and applies to
  one deployment, so it is run by hand against the production D1 database the
  same way migrations are, and deliberately not checked into `migrations/`.

Removing a row is harder than adding one: `auth_sessions` and
`auth_login_tokens` both reference `account_users` with `ON DELETE RESTRICT`, so
that user's sessions and unconsumed login tokens have to go first, and doing so
signs the identity out wherever it is currently in use.

The web app at `app.pickpic.photos` will sign the same address in with the same
link, which is a useful way to confirm the row is right before touching the
iPad.

## Each sign-in

Sessions last **30 days from creation and cannot be renewed in place** — the
lifetime is absolute so that a stolen cookie dies on a fixed date. Signing in
again mints a new one.

1. Open PickPic on the iPad. With no valid session it presents the account
   sheet by itself; otherwise it is behind the settings button.
2. Enter the account's email address and tap **Send Sign-In Link**.
3. Open Mail, press and hold the button in the email, and choose **Copy Link**.
   Running Mail beside PickPic in Split View makes this a two-tap round trip.
4. Paste into the app and tap **Sign In** (or use the Paste button, which does
   both).

The link expires 15 minutes after it is sent and works exactly once. Redeeming
it in Safari instead of the app signs the _browser_ in, not the iPad — the
session lands in a cookie the app cannot read, and the link is then spent.

## When uploads stop with "sign in again"

A 401 from any admin request clears the stored session, which stops the upload
queue rather than letting it retry against a credential that cannot work. Jobs
are left at `readyToUpload`, so **nothing is lost**: sign in again and they
resume where they stopped, including any transfer that was in flight.

The app warns inside the last 7 days of a session's life. That window is not
arbitrary — `BackgroundUploadSession` lets a transfer live up to 7 days, so a
batch started inside it can outlive the session that authorised it. Signing in
again before a shoot, while the queue is idle, is the cheap way to avoid that.

## What this replaced

The app used to send `CF-Access-Client-Id` / `CF-Access-Client-Secret` on every
admin request against `admin.pickpic.photos`. Those Keychain items are cleared
on first launch of the new build. The service token itself is still live
Cloudflare configuration until it is revoked in the dashboard — worth doing,
since nothing uses it any more.

Access protection on `admin.pickpic.photos` is unchanged and stays that way.
