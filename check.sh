#!/usr/bin/env bash
# JET uptime check. Runs on a GitHub Actions schedule (see .github/workflows/uptime.yml).
# DOWN means: connection failure/timeout, or HTTP 5xx after retries. 4xx counts as UP,
# because a Cloudflare bot challenge or an auth wall proves the site is reachable.
# Alerts go to ntfy (Jay's phone): once on the down transition, a reminder every hour
# while still down, and once on recovery.
set -uo pipefail

SITES=(
  "https://jettheagency.com"
  "https://jet.furniture"
  "https://jetexhibits.com"
  "https://jet-crm-sepia.vercel.app"
  "https://jet-ops-hub.vercel.app"
  "https://compass.jet.events"
  "https://jetestimatebuilder.netlify.app"
  "https://jet-bematrix-calc.netlify.app"
  "https://sage.jet.events"
  "https://jet-command-center-production.up.railway.app"
  # Not a site: the lead-pipeline canary's dead man's switch. It answers 200
  # while the canary's last fully clean run is recent and 503 once that goes
  # stale, has never happened, or cannot be read. It is here rather than in an
  # email because the canary is deliberately silent when healthy, so this is
  # the only thing that can tell "the lead pipeline is fine" apart from "the
  # thing watching it died". A 5xx is DOWN and a timeout is DOWN, which is
  # exactly the pair of failures worth hearing about. Loop L222.
  "https://jet-command-center-production.up.railway.app/api/lead-canary/health"
  # Not a site: the ops-watchdog scheduler's dead man's switch, same shape and same
  # reason as the lead-canary probe above. It answers 200 while the hourly cron has
  # stamped ops_watchdog_last_run within the last ~2h15m and 503 once that goes stale,
  # has never happened, or cannot be read. It replaces the ops-watchdog weekly
  # Monday all-clear email, which existed only to prove the same thing on a timer.
  # Loop L222, row C5 of the 2026-08-29 notification load audit.
  "https://msuhogoehzpixcnmsbzb.supabase.co/functions/v1/ops-watchdog"
  # Not a page, a static asset: jet.furniture served a 429 with a 7-day
  # Cache-Control on 2026-09-01, and Cloudflare cached and re-served that 429
  # for days while the homepage itself kept answering 200, unstyled. A
  # page-level check alone cannot see that failure, because 4xx counts as UP
  # for every other target here. This one target must answer 200 exactly, so
  # a cached error under it is caught in minutes, not days. L249.
  "https://jet.furniture/wp-content/themes/flatsome/assets/css/flatsome.css"
)
if [ -n "${EXTRA_URL:-}" ]; then SITES+=("$EXTRA_URL"); fi

UA="Mozilla/5.0 (compatible; JET-uptime; +https://github.com/jta333/jet-fallback)"

# What an alert calls a target. Everything here is a site, and its URL says so
# on a phone screen, with one exception: the canary health probe is a state
# check, not a page, so it gets a name a human can act on. Anything unlisted
# falls back to the URL, so this can never make an existing alert worse.
label_for() {
  case "$1" in
    */api/lead-canary/health) echo "Lead pipeline canary (stale, unreachable, or not deployed)" ;;
    */functions/v1/ops-watchdog) echo "Ops watchdog scheduler (stale, unreachable, or not deployed)" ;;
    */flatsome/assets/css/flatsome.css) echo "jet.furniture static assets (cached-error outage canary)" ;;
    *) echo "$1" ;;
  esac
}

# Which targets must answer 200 exactly, rather than merely answering.
#
# Every site here is a page, and for a page any answer proves reachability, so
# a 4xx counts as UP: a Cloudflare bot challenge or an auth wall is not an
# outage, and the real one was a 522. The canary probes are not pages. Their
# entire contract IS the status code, and the two ways they can be wrong are a
# 503 (gone stale) and a 404 (the route is gone, or was never deployed).
# Under the general rule that 404 would read as UP and the dead man's switch
# would sit green forever, which is a check that cannot fail. The flatsome.css
# asset is a page dependency, not a page: a real static asset never legitimately
# answers 4xx, so unlike the pages above, a 429/404 here means "reachable but
# wrong" and must be treated as down, not tolerated as a bot challenge. L249.
strict_200() {
  case "$1" in
    */api/lead-canary/health) return 0 ;;
    */functions/v1/ops-watchdog) return 0 ;;
    */flatsome/assets/css/flatsome.css) return 0 ;;
    *) return 1 ;;
  esac
}

# What a strict target's 200 must contain in its body to be believed, keyed
# per target since not every strict target shares one marker.
#
# A status code alone is NOT evidence for the canary probes, proven against
# the live URL on 2026-08-29: an unauthenticated request answered 307 to the
# sign-in page, and this script follows redirects, so it landed on a 200 HTML
# login page. Status-code-only logic would have called a dead man's switch
# that has never once worked UP, forever. Same family of bug as the 000000
# false-UP caught on 2026-08-14, and the same fix: make the check assert the
# thing it actually cares about. The flatsome.css asset has no such stand-in
# page to be redirected to, so its status code alone is the evidence: no
# marker required.
marker_for() {
  case "$1" in
    */api/lead-canary/health) echo '"status":"ok"' ;;
    */functions/v1/ops-watchdog) echo '"status":"ok"' ;;
    *) echo "" ;;
  esac
}

REMIND_SECS=3600

check_once() {
  # curl prints the -w code even when it fails (000 on timeout/DNS/connect errors),
  # so no fallback may be appended on failure: "000" + a fallback echo made "000000",
  # which slipped past the != "000" test and read a dead site as UP (caught by the
  # negative control on 2026-08-14). Sanitize to exactly three digits instead.
  local code body marker
  if strict_200 "$1"; then
    # Strict targets are judged on their body as well as their status, so the
    # response is kept instead of discarded. The code is appended on its own
    # last line so it survives whatever the body contains.
    body=$(curl -sS -L -A "$UA" --max-time 20 -w '
%{http_code}' "$1" 2>/dev/null || true)
    code=$(printf '%s' "$body" | tail -n 1)
  else
    body=""
    code=$(curl -sS -L -A "$UA" -o /dev/null --max-time 20 -w "%{http_code}" "$1" 2>/dev/null || true)
  fi
  code=${code: -3}
  case "$code" in
    [0-9][0-9][0-9]) ;;
    *) code="000" ;;
  esac
  # A strict target that returned 200 WITHOUT its marker did not really answer:
  # that is an auth redirect followed to a login page, or some other stand-in.
  # Report it as no answer, so it can never be read as healthy.
  if [ "$code" = "200" ] && strict_200 "$1"; then
    marker=$(marker_for "$1")
    if [ -n "$marker" ]; then
      case "$body" in
        *"$marker"*) ;;
        *) code="000" ;;
      esac
    fi
  fi
  echo "$code"
}

[ -s state.json ] || echo '{}' > state.json
now=$(date -u +%s)
new_state='{}'
down_lines=""
up_lines=""

for url in "${SITES[@]}"; do
  code="000"
  status="down"
  for attempt in 1 2 3; do
    code=$(check_once "$url")
    if [ "$code" != "000" ] && [ "$code" -lt 500 ]; then
      if strict_200 "$url" && [ "$code" != "200" ]; then
        # It answered, but not with the answer that means healthy. Keep
        # retrying and leave the status down if it never becomes 200.
        status="down"
      else
        status="up"
        break
      fi
    fi
    [ "$attempt" -lt 3 ] && sleep 10
  done

  prev=$(jq -r --arg u "$url" '.[$u].status // "up"' state.json)
  since=$(jq -r --arg u "$url" '.[$u].since // 0' state.json)
  last_alert=$(jq -r --arg u "$url" '.[$u].last_alert // 0' state.json)

  if [ "$status" = "down" ]; then
    if [ "$prev" != "down" ]; then
      since=$now
      last_alert=$now
      down_lines="${down_lines}DOWN: $(label_for "$url") (HTTP ${code})"$'\n'
    elif [ $((now - last_alert)) -ge $REMIND_SECS ]; then
      last_alert=$now
      mins=$(( (now - since) / 60 ))
      down_lines="${down_lines}STILL DOWN: $(label_for "$url") (~${mins} min, HTTP ${code})"$'\n'
    fi
  else
    if [ "$prev" = "down" ]; then
      mins=$(( (now - since) / 60 ))
      up_lines="${up_lines}RECOVERED: $(label_for "$url") (was down ~${mins} min)"$'\n'
    fi
    since=0
    last_alert=0
  fi

  echo "${status} ${code} ${url}"
  new_state=$(jq --arg u "$url" --arg s "$status" --argjson la "$last_alert" --argjson si "$since" \
    '.[$u] = {status: $s, last_alert: $la, since: $si}' <<< "$new_state")
done

printf '%s' "$new_state" > state.json

if [ -z "${NTFY_TOPIC:-}" ]; then
  echo "NTFY_TOPIC secret not set; skipping alerts."
  exit 0
fi

if [ -n "$down_lines" ]; then
  curl -sS --max-time 15 \
    -H "Title: JET site DOWN" \
    -H "Priority: urgent" \
    -H "Tags: rotating_light" \
    -d "$down_lines" \
    "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null || echo "WARNING: ntfy down-alert failed to send"
fi

if [ -n "$up_lines" ]; then
  curl -sS --max-time 15 \
    -H "Title: JET site recovered" \
    -H "Tags: white_check_mark" \
    -d "$up_lines" \
    "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null || echo "WARNING: ntfy recovery alert failed to send"
fi

exit 0
