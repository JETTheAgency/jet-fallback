#!/usr/bin/env bash
# JET Drive Audit Watcher dead man's switch. Runs on a GitHub Actions schedule
# (see .github/workflows/drive-watcher-health.yml), OUTSIDE StudioPro on purpose:
# the failure it catches is the watcher not running at all (laptop off, scheduled
# task gone, every pull failing), which nothing on StudioPro can report.
#
# The watcher (jet-claude-central, scripts/studiopro/drive-audit-watcher) posts one
# heartbeat per COMPLETE hourly run to an ntfy topic:
#   Title: jet-drive-watcher    Body: {"status":"ok","at":"<ISO-8601 UTC>"}
#
# ntfy.sh keeps messages about 12 hours, but the limit here is 24 hours (Jay,
# 2026-11-02: StudioPro is off most nights, and the watcher catches up on everything
# it missed when it comes back). So the newest heartbeat time is remembered in the
# state file, and only that remembered time is compared against the limit. A topic
# that cannot be read just leaves the time where it was: if reading stays broken, the
# switch goes off at 24 hours, which is the safe direction.
#
# Alerts are EMAIL via Resend with numbered repair steps, per the JET alert standard:
# once on the down transition, a reminder every 24 hours, once on recovery.
set -uo pipefail

NTFY_BASE="${NTFY_BASE:-https://ntfy.sh}"
NTFY_TITLE="jet-drive-watcher"
ALERT_TO="${ALERT_EMAIL_TO:-j@jet.events}"
ALERT_FROM="${ALERT_EMAIL_FROM:-JET Automation Watchdog <alerts@jet.events>}"
STATE_FILE="${STATE_FILE:-drive-watcher-health-state.json}"
SILENT_SECS="${SILENT_SECS:-86400}"
REMIND_SECS="${REMIND_SECS:-86400}"
# The real topic lives only in the secret: this repository is public, and anyone
# holding the topic could post a fake heartbeat and silence the alarm.
TOPIC="${TOPIC_OVERRIDE:-${DRIVE_WATCHER_NTFY_TOPIC:-}}"

now=$(date -u +%s)
measured_at=$(date -u -d "@${now}" +%Y-%m-%dT%H:%M:%SZ)

[ -s "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
[ "${RESET_STATE:-}" = "true" ] && echo '{}' > "$STATE_FILE" && echo "state reset by request"

prev=$(jq -r '.status // "up"' "$STATE_FILE")
since=$(jq -r '.since // 0' "$STATE_FILE")
last_alert=$(jq -r '.last_alert // 0' "$STATE_FILE")
# First run ever (or an evicted cache): start the clock now instead of alarming at once.
last_seen=$(jq -r ".last_seen // ${now}" "$STATE_FILE")

read_note=""
if [ -z "$TOPIC" ]; then
  read_note="The DRIVE_WATCHER_NTFY_TOPIC secret is not set on this repository, so no heartbeat can be read."
else
  resp=$(curl -sS -L --max-time 25 -w '\n%{http_code}' "${NTFY_BASE}/${TOPIC}/json?poll=1&since=12h" 2>/dev/null || true)
  code=$(printf '%s' "$resp" | tail -n 1)
  if [ "$code" != "200" ]; then
    read_note="Reading the heartbeat topic answered HTTP ${code}."
  else
    newest=$(printf '%s' "$resp" | sed '$d' \
      | jq -r --arg t "$NTFY_TITLE" 'select(type=="object" and .event=="message" and .title==$t) | .time' 2>/dev/null \
      | sort -n | tail -n 1)
    if [ -n "$newest" ] && [ "$newest" -gt "$last_seen" ]; then last_seen=$newest; fi
  fi
fi
[ -n "$read_note" ] && echo "WARNING: ${read_note}"

age=$((now - last_seen))
age_h=$((age / 3600))
last_seen_at=$(date -u -d "@${last_seen}" +%Y-%m-%dT%H:%M:%SZ)

send_email() {
  local subject="$1" bodytext="$2"
  if [ -z "${RESEND_API_KEY:-}" ]; then
    echo "RESEND_API_KEY not set; would have sent:"; echo "SUBJECT: ${subject}"; printf '%s\n' "$bodytext"
    return 0
  fi
  local payload out hcode
  payload=$(jq -n --arg from "$ALERT_FROM" --arg to "$ALERT_TO" --arg subject "$subject" --arg text "$bodytext" \
                  '{from: $from, to: [$to], subject: $subject, text: $text}')
  out=$(curl -sS --max-time 20 -X POST "https://api.resend.com/emails" \
        -H "Authorization: Bearer ${RESEND_API_KEY}" -H "Content-Type: application/json" \
        -d "$payload" -w '\n%{http_code}' 2>/dev/null || true)
  hcode=$(printf '%s' "$out" | tail -n 1)
  if [ "$hcode" != "200" ]; then
    echo "WARNING: alert email failed to send (HTTP ${hcode}): $(printf '%s' "$out" | sed '$d')"
    return 1
  fi
  echo "Alert email sent (HTTP 200): ${subject}"
}

if [ "$age" -gt "$SILENT_SECS" ]; then
  echo "unhealthy: last heartbeat ${last_seen_at}, ${age_h}h ago"
  should_send="no"
  if [ "$prev" != "down" ]; then
    since=$now; last_alert=$now; should_send="first"
  elif [ $((now - last_alert)) -ge "$REMIND_SECS" ]; then
    last_alert=$now; should_send="reminder"
  fi
  if [ "$should_send" != "no" ]; then
    subject="RED: JET Drive Audit Watcher has not run for ${age_h} hours (measured ${measured_at})"
    [ "$should_send" = "reminder" ] && subject="RED: JET Drive Audit Watcher still not running, ${age_h} hours (measured ${measured_at})"
    read -r -d '' body <<EOF || true
WHAT HAPPENED
The Drive Audit Watcher on StudioPro has not finished a run since ${last_seen_at} UTC,
${age_h} hours before this check at ${measured_at} UTC. It runs every hour while StudioPro is on.
${read_note}

WHY IT MATTERS
While it is not running, nothing alerts on bulk downloads, bulk deletes or files shared
outside JET. Nothing is lost: when it runs again it checks everything it missed (up to 7
days back), so a problem is caught late, not never.

FIX IT
1. Is StudioPro on? If it is off on purpose (travel, shut down), there is nothing to fix.
   Turn it on when convenient and this clears itself within the hour.
2. If StudioPro is on and awake, open PowerShell on it and run this one line:
   Start-ScheduledTask -TaskName "JET Drive Audit Watcher"
3. Wait two minutes, then run this one line and read the last few lines:
   Get-Content C:\Users\jayca\dev\_machine-state\drive-audit-watcher\watcher.log -Tail 15
4. If the log shows an error, or the task will not run, open Claude Code on StudioPro and paste:

   ----- paste into Claude Code (Model + effort: Sonnet 5, medium; single session; repo: jet-claude-central) -----
   Use my JET brain. The Drive Audit Watcher's dead man's switch says it has not finished a
   run for ${age_h} hours while StudioPro is on. Read the tail of
   C:\Users\jayca\dev\_machine-state\drive-audit-watcher\watcher.log and
   Get-ScheduledTaskInfo -TaskName "JET Drive Audit Watcher" (LastRunTime, LastTaskResult),
   find the root cause, fix it, and confirm the next hourly run logs a result line.
   ----- end paste -----

DONE WHEN
A GREEN "recovered" email arrives from this watchdog, within about an hour of the fix.

Measured by the Drive watcher dead man's switch at ${measured_at} UTC.
Runs: https://github.com/JETTheAgency/jet-fallback/actions/workflows/drive-watcher-health.yml

If this is wrong or already fixed, reply and it gets tuned.
EOF
    send_email "$subject" "$body" || true
  else
    echo "Still down, next reminder in $(( (REMIND_SECS - (now - last_alert)) / 60 )) min."
  fi
  status="down"
else
  echo "healthy: last heartbeat ${last_seen_at}, $((age / 60)) min ago"
  if [ "$prev" = "down" ]; then
    mins=$(( (now - since) / 60 ))
    send_email "GREEN: JET Drive Audit Watcher is running again after ~${mins} min (measured ${measured_at})" \
"WHAT HAPPENED
The Drive Audit Watcher finished a run again at ${last_seen_at} UTC.

WHY IT MATTERS
It has already checked everything it missed while it was down (up to 7 days back). Any
alert from that period arrives marked as a catch-up.

FIX IT
1. Nothing to do.

DONE WHEN
Already done.

If this is wrong or already fixed, reply and it gets tuned." || true
  fi
  status="up"; since=0; last_alert=0
fi

jq -n --arg s "$status" --argjson ls "$last_seen" --argjson la "$last_alert" --argjson si "$since" \
  '{status: $s, last_seen: $ls, last_alert: $la, since: $si}' > "$STATE_FILE"

# Exit 0 whenever the check RAN: the email is the signal. A red workflow run means this
# script itself broke, never a second alert for the same incident.
echo "check complete, status=${status}"
exit 0
