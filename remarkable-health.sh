#!/usr/bin/env bash
# JET reMarkable PDF runner health check. Runs on a GitHub Actions schedule
# (see .github/workflows/remarkable-health.yml), OUTSIDE homedrums on purpose:
# the failures this exists to catch are the runner's own machine being off, its
# scheduled task never firing, and its reMarkable web session quietly expiring.
# Nothing running on homedrums can be trusted to report any of those.
#
# The runner (C:\JET\remarkable-pdf\run.ps1, loop L240) posts ONE status per run
# to an ntfy topic:
#   Title: jet-remarkable-pdf
#   Body : {"status":"ok|fail","reason":"none|login_expired|render_failed|
#            upload_failed|crash","rendered":N,"pending":M,"uploaded":K,
#            "at":"<ISO-8601 UTC>"}
# Counts and reason codes only. Notebook names are client names and never travel.
#
# UNHEALTHY means any of:
#   - no status in the last 12 hours (six missed runs at the 2 hour cadence)
#   - the latest status says fail, whatever its reason
#   - the topic could not be read, answered non-200, or its latest message could
#     not be parsed
#   - the REMARKABLE_NTFY_TOPIC secret is missing, so nothing can be evaluated
# The last two are deliberate: a check that cannot run is RED, never a silent pass.
#
# The window is 12 hours, not 24: ntfy.sh keeps messages for about 12 hours, so a
# longer window would read an expired cache as healthy.
#
# Alerts are EMAIL via Resend with numbered repair steps matched to the actual
# cause, per the JET alert standard. Sent once on the down transition, repeated
# hourly while still down, once on recovery.
set -uo pipefail

NTFY_BASE="${NTFY_BASE:-https://ntfy.sh}"
NTFY_TITLE="${NTFY_TITLE:-jet-remarkable-pdf}"
ALERT_TO="${ALERT_EMAIL_TO:-j@jet.events}"
ALERT_FROM="${ALERT_EMAIL_FROM:-JET Automation Watchdog <alerts@jet.events>}"
STATE_FILE="${STATE_FILE:-remarkable-health-state.json}"
# One incident is one email plus a daily reminder, not one every hour. The
# 2026-09-09 login_expired outage sent four emails in twelve hours and Jay
# still missed it, so volume was never the thing that was missing.
REMIND_SECS="${REMIND_SECS:-86400}"
SILENT_SECS="${SILENT_SECS:-43200}"

# topic_override lets a manual run prove a condition against a throwaway topic
# without touching the real one. The real topic lives only in the secret, because
# this repository is public and anyone holding the topic could post a fake ok
# status and silence the alarm.
TOPIC="${TOPIC_OVERRIDE:-${REMARKABLE_NTFY_TOPIC:-}}"

now=$(date -u +%s)
measured_at=$(date -u -d "@${now}" +%Y-%m-%dT%H:%M:%SZ)

[ -s "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
if [ "${RESET_STATE:-}" = "true" ]; then
  echo '{}' > "$STATE_FILE"
  echo "state reset by request"
fi

# Exactly one cause is set, and it selects the repair steps. Steps for a healthy
# subsystem are worse than no steps: they send Jay to fix the wrong thing and
# teach him the alert is noise. This is the L222 bug, and it is not repeated here.
cause=""            # login_expired | render_failed | upload_failed | crash | silent | cannot_evaluate
headline=""
what_happened=""
status_at="none inside the 12 hour window"

fail_eval() {
  cause="cannot_evaluate"
  headline="JET reMarkable PDF watchdog cannot read the runner status, health is UNKNOWN"
  what_happened="$1"
}

if [ -z "$TOPIC" ]; then
  fail_eval "The REMARKABLE_NTFY_TOPIC secret is not set on this repository, so the watchdog has no topic to read and could not evaluate anything at ${measured_at} UTC."
else
  # curl prints the -w code even when the request fails, so a transport failure
  # lands as 000 and is read as unevaluable rather than skipped.
  resp=$(curl -sS -L --max-time 25 -w '\n%{http_code}' \
         "${NTFY_BASE}/${TOPIC}/json?poll=1&since=12h" 2>/dev/null || true)
  code=$(printf '%s' "$resp" | tail -n 1)
  raw=$(printf '%s' "$resp" | sed '$d')

  if [ "$code" != "200" ]; then
    fail_eval "Reading the runner status topic answered HTTP ${code} at ${measured_at} UTC, so the runner's health is unknown. Unknown is treated as broken."
  else
    # ntfy answers newline-delimited JSON. Keep only real messages carrying the
    # runner's title, then let the newest one decide. An empty answer is not an
    # error: it means nothing has been posted inside the cache window.
    latest=$(printf '%s\n' "$raw" \
      | jq -c 'select(type=="object") | select(.event=="message") | select(.title==$t)' \
             --arg t "$NTFY_TITLE" 2>/dev/null \
      | jq -s 'sort_by(.time) | last // empty' 2>/dev/null || true)

    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
      cause="silent"
      headline="JET reMarkable PDF runner has gone silent, no status in over 12 hours"
      what_happened="No run status reached the topic in the last 12 hours, checked at ${measured_at} UTC. The runner posts one on every run and runs every 2 hours, so at least six runs are missing."
    else
      msg_time=$(printf '%s' "$latest" | jq -r '.time // 0')
      payload=$(printf '%s' "$latest" | jq -r '.message // ""')
      parsed=$(printf '%s' "$payload" | jq -c '.' 2>/dev/null || true)

      if [ -z "$parsed" ]; then
        fail_eval "The newest run status on the topic could not be read as JSON, so the runner's health is unknown at ${measured_at} UTC. Unknown is treated as broken."
      else
        st=$(printf '%s' "$parsed" | jq -r '.status // ""')
        rs=$(printf '%s' "$parsed" | jq -r '.reason // ""')
        rendered=$(printf '%s' "$parsed" | jq -r '.rendered // "?"')
        pending=$(printf '%s' "$parsed" | jq -r '.pending // "?"')
        uploaded=$(printf '%s' "$parsed" | jq -r '.uploaded // "?"')
        status_at=$(printf '%s' "$parsed" | jq -r '.at // "not stamped"')
        age_mins=$(( (now - msg_time) / 60 ))

        if [ $((now - msg_time)) -gt "$SILENT_SECS" ]; then
          cause="silent"
          headline="JET reMarkable PDF runner has gone silent, no status in over 12 hours"
          what_happened="The newest run status is ${age_mins} minutes old, past the 12 hour limit, checked at ${measured_at} UTC. The runner runs every 2 hours, so at least six runs are missing."
        elif [ "$st" = "ok" ]; then
          echo "healthy: status ok, reason ${rs}, rendered ${rendered}, pending ${pending}, uploaded ${uploaded}, posted ${status_at}, ${age_mins} min ago"
        elif [ "$st" = "fail" ]; then
          case "$rs" in
            login_expired|render_failed|upload_failed|crash) cause="$rs" ;;
            *) cause="crash" ;;
          esac
          case "$cause" in
            login_expired) headline="JET reMarkable PDF runner cannot sign in, its web session has expired" ;;
            render_failed) headline="JET reMarkable PDF runner rendered nothing, their web app has probably changed" ;;
            upload_failed) headline="JET reMarkable PDF runner rendered PDFs but could not upload them to Drive" ;;
            crash)         headline="JET reMarkable PDF runner crashed, no PDFs are being produced" ;;
          esac
          what_happened="The runner reported status fail with reason ${cause} at ${status_at} (posted ${age_mins} minutes before this check at ${measured_at} UTC). It rendered ${rendered}, uploaded ${uploaded}, and ${pending} notebook(s) are still waiting."
        else
          fail_eval "The newest run status carried an unrecognised status value at ${measured_at} UTC, so the runner's health is unknown. Unknown is treated as broken."
        fi
      fi
    fi
  fi
fi

prev=$(jq -r '.status // "up"' "$STATE_FILE")
since=$(jq -r '.since // 0' "$STATE_FILE")
last_alert=$(jq -r '.last_alert // 0' "$STATE_FILE")

send_email() {
  local subject="$1" bodytext="$2"
  if [ -z "${RESEND_API_KEY:-}" ]; then
    echo "RESEND_API_KEY not set; would have sent:"
    echo "SUBJECT: ${subject}"
    printf '%s\n' "$bodytext"
    return 0
  fi
  local payload
  payload=$(jq -n --arg from "$ALERT_FROM" --arg to "$ALERT_TO" \
                  --arg subject "$subject" --arg text "$bodytext" \
                  '{from: $from, to: [$to], subject: $subject, text: $text}')
  local out hcode
  out=$(curl -sS --max-time 20 -X POST "https://api.resend.com/emails" \
        -H "Authorization: Bearer ${RESEND_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" -w '\n%{http_code}' 2>/dev/null || true)
  hcode=$(printf '%s' "$out" | tail -n 1)
  if [ "$hcode" != "200" ]; then
    # Resend's own response body carries the real reason. Never log the key.
    echo "WARNING: alert email failed to send (HTTP ${hcode}): $(printf '%s' "$out" | sed '$d')"
    return 1
  fi
  echo "Alert email sent (HTTP 200): ${subject}"
}

steps_for_cause() {
  # One bounded action per step, naming what Jay can SEE, with the direct link,
  # and a paste-ready prompt wherever the fix is Claude's rather than his.
  case "$1" in
    login_expired)
      cat <<'STEPS'
1. Nothing is broken on your side. The reMarkable web session the runner uses has expired
   and only a real sign-in can renew it. On StudioPro, open Claude Code and paste this:

   ----- paste into Claude Code (Model + effort: Sonnet 5, medium) -----
   Use my JET brain. Open and FULLY read the "Re-login" section of
   `C:\Users\jayca\jet-claude-central\docs\loops\L240-remarkable-pdf-automation.md`
   (absolute path; jayca = StudioPro).
   The reMarkable PDF runner reported `login_expired`. Follow that section: open a headed
   browser at `https://my.remarkable.com`, have me sign in as `j@jet.events`, save the
   session state, copy it to homedrums over `ssh Jay@100.100.54.91`, prove it in a fresh
   headless context by exporting one notebook, then start the task once and confirm the
   next status says ok.
   ----- end paste -----

2. When Claude asks you to sign in, sign in as `j@jet.events` on the window it opens.
   That is the only part it cannot do for you.
STEPS
      ;;
    render_failed)
      cat <<'STEPS'
1. Open `https://my.remarkable.com` in a browser and sign in as `j@jet.events`. Open any
   notebook and look for the export or download control (the button the runner clicks to
   get a PDF). Note whether it is still there and what it is now called. If the whole site
   looks redesigned, that is the answer: they shipped a change and the runner needs updating.

2. On StudioPro, open Claude Code and paste this:

   ----- paste into Claude Code (Model + effort: Opus 5, high) -----
   Use my JET brain. Open and FULLY read
   `C:\Users\jayca\jet-claude-central\docs\loops\L240-remarkable-pdf-automation.md`.
   The reMarkable PDF runner reported `render_failed`, which means it exported zero PDFs
   out of the notebooks it tried. Re-run the gate by hand first: sign in at
   `https://my.remarkable.com`, export ONE notebook to PDF, render page 1 with `pdftoppm`
   and LOOK at it. Then repair `C:\JET\remarkable-pdf\render.py` on homedrums against
   whatever their web app now does, prove one real render end to end, and report with the
   rendered page as the evidence. A zero exit code is not proof.
   ----- end paste -----
STEPS
      ;;
    upload_failed)
      cat <<'STEPS'
1. The PDFs were produced, so nothing is lost. They are sitting in `C:\JET\remarkable-pdf\out`
   on homedrums and only the Google Drive upload failed. The usual cause is the Drive
   credential on that machine (loop `L239`).

2. On StudioPro, open Claude Code and paste this:

   ----- paste into Claude Code (Model + effort: Opus 5, medium) -----
   Use my JET brain. Open and FULLY read
   `C:\Users\jayca\jet-claude-central\docs\loops\L239-jet-owned-google-oauth-client.md`.
   The reMarkable PDF runner reported `upload_failed`, so the `jetnotes:` rclone remote on
   homedrums is not authenticating. Over `ssh Jay@100.100.54.91`, run
   `C:\JET\remarkable-sync\rclone.exe --config C:\JET\remarkable-sync\rclone.conf lsd jetnotes:`
   and read the real error. Repair it by re-running L239's homedrums steps. If the config
   itself is the problem, the rollback is one line: copy
   `C:\JET\remarkable-sync\rclone.conf.bak-L239-2026-09-03` over
   `C:\JET\remarkable-sync\rclone.conf`. Nothing was ever revoked, so that always works.
   Then re-run the task and confirm the next status says ok.
   ----- end paste -----
STEPS
      ;;
    crash|silent)
      cat <<'STEPS'
1. Check homedrums first, because it explains most of these. Is the desktop on, and are you
   still signed in at its screen? Both reMarkable tasks run only inside your interactive
   session, so a sign-out or a reboot that lands on the lock screen stops them cold.

2. Kick the job by hand, one line:
   `ssh Jay@100.100.54.91 'schtasks /Run /TN "JET reMarkable PDF Render"'`

3. Read what it said, one line:
   `ssh Jay@100.100.54.91 'powershell -NoProfile -Command "Get-Content C:\JET\remarkable-pdf\run.log -Tail 20"'`

4. If that does not explain it, on StudioPro open Claude Code and paste this:

   ----- paste into Claude Code (Model + effort: Opus 5, high) -----
   Use my JET brain. Open and FULLY read
   `C:\Users\jayca\jet-claude-central\docs\loops\L240-remarkable-pdf-automation.md`.
   The reMarkable PDF runner has gone silent or crashed. Over `ssh Jay@100.100.54.91`:
   confirm the machine is up, run `Get-ScheduledTaskInfo -TaskName "JET reMarkable PDF Render"`
   and read `LastTaskResult` and `LastRunTime`, then read the tail of
   `C:\JET\remarkable-pdf\run.log`. Find the root cause, fix it, run the task once, and
   confirm a fresh ok status reaches the topic. Do not weaken the check to make it pass.
   ----- end paste -----
STEPS
      ;;
    cannot_evaluate)
      cat <<'STEPS'
1. This watchdog could not read the runner's status, so nothing about the runner itself is
   confirmed. First check whether the status service is simply down: open `https://ntfy.sh`
   in a browser. If it does not load, there is nothing to fix and the next check will clear
   itself.

2. If it does load, the topic setting is probably missing. Open
   `https://github.com/jta333/jet-fallback/settings/secrets/actions` and confirm a secret
   named `REMARKABLE_NTFY_TOPIC` is listed. If it is not, it must be set to the same topic
   the runner posts to, which is in `C:\JET\remarkable-pdf\config.json` on homedrums.

3. If both look right, on StudioPro open Claude Code and paste this:

   ----- paste into Claude Code (Model + effort: Opus 5, medium) -----
   Use my JET brain. The reMarkable PDF watchdog in `jta333/jet-fallback` reported that it
   could not evaluate the runner status. Read `remarkable-health.sh` in that repository and
   the newest failing run at
   `https://github.com/jta333/jet-fallback/actions/workflows/remarkable-health.yml`.
   Find why the topic read failed, fix it, and prove the fix by dispatching the workflow and
   reading the run log. Never make an unreadable status count as healthy.
   ----- end paste -----
STEPS
      ;;
  esac
}

done_when_for_cause() {
  case "$1" in
    login_expired)   echo 'A new PDF appears in the `_JET Notes` folder in Google Drive within about 2 hours, and no further RED email arrives.' ;;
    render_failed)   echo "One notebook exports to a PDF you can open and read, and the next runner status says ok." ;;
    upload_failed)   echo 'The PDFs already sitting on homedrums appear in the `_JET Notes` folder in Google Drive, and the next status says ok.' ;;
    crash|silent)    echo "A fresh status reaches the watchdog within 2 hours and no further RED email arrives." ;;
    cannot_evaluate) echo 'The next run of this watchdog reports healthy instead of unreadable. Runs are listed at `https://github.com/jta333/jet-fallback/actions/workflows/remarkable-health.yml`' ;;
  esac
}

if [ -n "$cause" ]; then
  echo "unhealthy: cause=${cause}"
  should_send="no"
  if [ "$prev" != "down" ]; then
    since=$now
    last_alert=$now
    should_send="first"
  elif [ $((now - last_alert)) -ge "$REMIND_SECS" ]; then
    last_alert=$now
    should_send="reminder"
  fi

  mins=$(( (now - since) / 60 ))

  if [ "$should_send" != "no" ]; then
    if [ "$should_send" = "reminder" ]; then
      subject="RED: ${headline}, still unresolved after ~${mins} min (measured ${measured_at})"
    else
      subject="RED: ${headline} (measured ${measured_at})"
    fi

    read -r -d '' body <<EOF || true
WHAT HAPPENED
${what_happened}

WHY IT MATTERS
This is the automation that turns your reMarkable notes into readable PDFs in the
\`_JET Notes\` folder in Google Drive. While it is down, the tablet backup keeps running and
nothing is lost, but the notes arriving in Drive stay in the tablet's own format, which
nothing outside the reMarkable app can open. Notes written now pile up until it is fixed.

FIX IT
$(steps_for_cause "$cause")

DONE WHEN
$(done_when_for_cause "$cause")

Measured by the reMarkable PDF watchdog at ${measured_at} UTC. Newest runner status seen: ${status_at}.
Watchdog runs: \`https://github.com/jta333/jet-fallback/actions/workflows/remarkable-health.yml\`

If this is wrong or already fixed, reply and it gets tuned.
EOF
    send_email "$subject" "$body" || true
  else
    echo "Still down, next reminder in $(( (REMIND_SECS - (now - last_alert)) / 60 )) min."
  fi

  jq -n --argjson la "$last_alert" --argjson si "$since" --arg c "$cause" \
    '{status: "down", cause: $c, last_alert: $la, since: $si}' > "$STATE_FILE"
else
  if [ "$prev" = "down" ]; then
    mins=$(( (now - since) / 60 ))
    read -r -d '' rbody <<EOF || true
WHAT HAPPENED
The reMarkable PDF runner reported a healthy run again when checked at ${measured_at} UTC,
after roughly ${mins} minutes unhealthy. Its newest status is stamped ${status_at}.

WHY IT MATTERS
Notes written while it was down are picked up automatically on the next passes, newest
first, up to 30 per run. Nothing needs to be re-done by hand.

FIX IT
1. Open the \`_JET Notes\` folder in Google Drive and confirm PDFs from the outage window
   have appeared. They sit in folders matching the ones on the tablet.
2. If anything is still missing after about 8 hours, reply to this email and it gets looked at.

DONE WHEN
The notes you wrote during the outage are readable PDFs in \`_JET Notes\`.

If this is wrong or already fixed, reply and it gets tuned.
EOF
    send_email "GREEN: JET reMarkable PDF runner recovered after ~${mins} min (measured ${measured_at})" "$rbody" || true
  fi
  jq -n '{status: "up", cause: "", last_alert: 0, since: 0}' > "$STATE_FILE"
fi

# Always exit 0 when the check RAN, even if it found a problem: the email is the
# signal, and a non-zero exit here would fire a GitHub Actions failure email for
# the same incident, which is the alert-multiplying the standard forbids. That
# leaves a red workflow run meaning exactly one thing: this script itself broke.
echo "check complete, cause=${cause:-none}"
exit 0
