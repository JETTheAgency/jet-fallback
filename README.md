# jet-fallback

JET's outage kit, built after the 2026-08-13 hosting.com outage (loop L191 in
`jet-claude-central`). Three things live here:

1. **The emergency fallback page** (`index.html`), deployed on Vercel. One static page:
   JET The Agency, phone, email, Jay. It exists so a hosting outage never again means
   a dead screen for a customer.
2. **The uptime monitor** (`.github/workflows/uptime.yml` + `check.sh`). GitHub Actions
   checks all JET sites and apps about every 5 minutes and pushes to ntfy (Jay's phone)
   on the down transition, hourly while down, and once on recovery. DOWN = timeout or
   HTTP 5xx; a 4xx (bot challenge, auth wall) counts as UP because the server answered.
3. **The DNS failover switch** (`scripts/failover.ps1`). One command points
   `jettheagency.com` or `jet.furniture` at the fallback page; one command restores.

## Runbook: a WP site is down

Turn the fallback on (from either laptop):

```
powershell -File scripts/failover.ps1 -Domain jettheagency.com -Mode on
```

When hosting recovers, restore:

```
powershell -File scripts/failover.ps1 -Domain jettheagency.com -Mode off
```

Same for `jet.furniture`. Add `-DryRun` to preview. Requires the Cloudflare token at
`%USERPROFILE%\.claude\secrets\cloudflare-jet-dns-token.txt` (Zone Read + DNS Edit on
both zones).

Full teaching-format documentation of every piece: `jet-claude-central`
`docs/guides/2026-08-14-outage-fallback-and-monitoring.md`.

This repo is public so the uptime schedule gets unlimited GitHub Actions minutes.
Nothing secret lives here: the page content is public by definition, the monitored URLs
are public, and the ntfy topic is a repo secret.

## Make automation health watchdog (`make-health.sh`)

Watches the two Make scenarios that build each new JET project's Google Drive folder
tree, and emails Jay when either stops working.

- **Runs:** `.github/workflows/make-health.yml`, every 15 minutes, plus manual
  `workflow_dispatch` with a `force_test` input that forces a RED so the alert path can
  be proven end to end.
- **Watches:** Make scenarios `2785090` (Google Drive Folder Creation on Item Creation)
  and `2798917` (File Upload Sync to Google Drive Subfolder), and their webhook queues.
- **Unhealthy means:** scenario switched off, flagged invalid by Make, more than
  `QUEUE_LIMIT` events stuck in its webhook queue, or the Make API unreadable. Unreadable
  counts as unhealthy on purpose: a check that cannot run is never a silent pass.
- **Alerts:** one merged email per incident via Resend, sent once on the down transition,
  repeated hourly while unresolved, and once on recovery. Repair steps are selected to
  match the actual cause, so a healthy subsystem is never blamed.
- **Why it lives here and not in Make:** the failure it catches is Make deactivating a
  scenario, so nothing inside Make can be trusted to report it. On 2026-08-25 the Drive
  scenario was auto-deactivated by a revoked Google refresh token and nobody was told for
  nine days.
- **A red run of this workflow means the script itself broke.** A detected problem with
  the scenarios exits 0 and emails instead, so one incident never sends two notifications.

### Secrets it needs

| Secret | What | Where to get it |
| --- | --- | --- |
| `MAKE_API_TOKEN` | Make API token, scopes `scenarios:read` and `hooks:read` | Make: avatar (bottom left) then Profile then the API tab then Add token |
| `RESEND_API_KEY` | Resend sending-only key scoped to `jet.events` | `https://resend.com/api-keys` |
| `ALERT_EMAIL_TO` | optional, defaults to `j@jet.events` | n/a |

## reMarkable PDF runner watchdog (`remarkable-health.sh`)

Watches the JET reMarkable PDF runner on homedrums (brain loop `L240`), which renders Jay's
tablet notes to readable PDFs and copies them into the `_JET Notes` folder in Google Drive.

- **Runs:** `.github/workflows/remarkable-health.yml`. The 15 minute schedule is commented
  out until the runner exists on homedrums, so today it is manual only:
  `workflow_dispatch` with `topic_override` (read a throwaway topic instead of the real one,
  so a condition can be proven without touching production) and `reset_state` (clear the
  up/down state so a transition email fires again).
- **Watches:** one ntfy topic. The runner posts a single status per run, titled
  `jet-remarkable-pdf`, carrying `status`, `reason`, and the counts `rendered`, `pending`,
  `uploaded`. Counts and reason codes only: notebook names are client names and never travel.
- **Unhealthy means:** no status in the last 12 hours (six missed runs at the 2 hour cadence),
  or the latest status says `fail`, or the topic answered non-200, or its newest message could
  not be parsed, or the `REMARKABLE_NTFY_TOPIC` secret is missing. The last three count as
  unhealthy on purpose: a check that cannot run is never a silent pass.
- **Why 12 hours and not 24:** `ntfy.sh` keeps messages for about 12 hours, so a longer window
  would read an expired cache as healthy.
- **Alerts:** one email per incident via Resend, sent once on the down transition, repeated
  hourly while unresolved, once on recovery. The repair steps are selected by the reported
  reason (`login_expired`, `render_failed`, `upload_failed`, `crash`, plus `silent` and
  `cannot evaluate`), so a healthy subsystem is never blamed.
- **Why it lives here and not on homedrums:** the failures it catches are that machine being
  off, its scheduled task never firing, and its reMarkable web session quietly expiring.
  Nothing running there can report any of those.
- **A red run of this workflow means the script itself broke.** A detected problem with the
  runner exits 0 and emails instead, so one incident never sends two notifications.

### Secrets it needs

| Secret | What | Where to get it |
| --- | --- | --- |
| `REMARKABLE_NTFY_TOPIC` | The ntfy topic the runner posts to. Not committed: this repository is public, and anyone holding the topic could post a fake `ok` and silence the alarm. | Generated when the runner is built on homedrums; it is the `topic` value in `C:\JET\remarkable-pdf\config.json` |
| `RESEND_API_KEY` | shared with `make-health` | `https://resend.com/api-keys` |
| `ALERT_EMAIL_TO` | optional, defaults to `j@jet.events` | n/a |

Set the topic with one line, from a machine whose `gh` is signed in as `jta333`:

```
gh secret set REMARKABLE_NTFY_TOPIC --repo jta333/jet-fallback --body "THE_TOPIC"
```

**Merging this to `main` is safe, because the schedule is commented out.** It has to reach
`main` to be testable at all: GitHub only offers `workflow_dispatch` for workflows present on
the default branch, so a workflow living on a feature branch cannot be run even manually and
answers `404` to a dispatch. Proven on 2026-09-03: `make-health.yml` dispatched successfully
against that same feature branch while `remarkable-health.yml` on that branch returned `404`.

**Turn the schedule on only when the runner is live on homedrums**, in the same change that
sets `REMARKABLE_NTFY_TOPIC`. Uncomment the two `schedule` lines in the workflow. Enabled any
earlier, the check correctly finds no status, calls the runner silent, and emails `RED:` every
hour about an automation that does not exist yet.

## Drive Audit Watcher dead man's switch (`drive-watcher-health.sh`)

Watches the JET Drive Audit Watcher on StudioPro (brain loop `L310`), which alerts on bulk
downloads, bulk deletes and outside sharing in Google Drive.

- **Runs:** `.github/workflows/drive-watcher-health.yml`, hourly at :23, plus
  `workflow_dispatch` with `topic_override` and `reset_state` (same meaning as above).
- **Watches:** one ntfy topic (secret `DRIVE_WATCHER_NTFY_TOPIC`). The watcher posts one
  heartbeat per complete hourly run, titled `jet-drive-watcher`.
- **Unhealthy means:** no heartbeat for 24 hours (Jay, 2026-11-02). StudioPro is off most
  nights, and the watcher checks everything it missed when it comes back, so a shorter limit
  would only report a closed laptop.
- **Why 24 hours works with a 12 hour cache:** the newest heartbeat time is kept in the state
  file, and only that time is compared to the limit. A topic that cannot be read leaves it
  where it was, so a broken read trips the switch at 24 hours instead of passing silently.
- **Alerts:** one email via Resend on the down transition, a reminder every 24 hours, one on
  recovery.
