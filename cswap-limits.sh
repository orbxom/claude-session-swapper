#!/usr/bin/env bash
# cswap-limits.sh — show Claude usage limits for every saved profile.
#
# Usage: cswap-limits.sh [options] [<name>…]
set -euo pipefail

_CSWAP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cswap-lib.sh"
[ -r "$_CSWAP_LIB" ] || { echo "cswap-lib.sh missing next to $(basename "$0")" >&2; exit 1; }
source "$_CSWAP_LIB"
unset _CSWAP_LIB

USAGE_URL="https://api.anthropic.com/api/oauth/usage"
TOKEN_URL="https://platform.claude.com/v1/oauth/token"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"   # Claude Code's OAuth client
BAR_WIDTH=10

NO_REFRESH=0
NAMES=()

usage() {
  cat <<EOF
Usage: cswap-limits.sh [options] [<name>…]

Fetches the 5-hour and 7-day usage windows for each saved profile (all of them
by default) from the same endpoint Claude Code's /usage uses, and prints one
block per profile. The active profile uses the live token; the others use the
token saved in their profile.

A saved token is usually expired by the time you ask. For a non-active
profile, cswap refreshes it and writes the new token pair back into the
profile. The live token is never refreshed here — a running claude owns it —
so an expired active profile prints "token expired (open claude to refresh)".

Options:
  --no-refresh   Don't refresh expired saved tokens; report them as expired.
  -h, --help     Show this help and exit.

Test seams (not for normal use):
  CSWAP_CURL     Path to a curl replacement (receives curl's arguments).
  CSWAP_NOW      Current time as epoch seconds.

One profile failing never stops the others. Exits 0 if any profile rendered,
1 if none did, 2 on bad arguments.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-refresh) NO_REFRESH=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "unknown flag: $1" >&2; exit 2 ;;
    *)            valid_profile_name "$1" || { echo "invalid profile name: '$1'" >&2; exit 2; }
                  NAMES+=("$1"); shift ;;
  esac
done

need jq
CURL="${CSWAP_CURL:-curl}"
[ -n "${CSWAP_CURL:-}" ] || need curl
NOW="${CSWAP_NOW:-$(date +%s)}"

# --- http --------------------------------------------------------------------

# http <method> <url> <token> [<json body>]: prints body, then the status code
# on the final line. Callers split on the last newline.
http() {
  local method="$1" url="$2" token="$3" body="${4:-}"
  local -a args=(-sS -m 15 -w $'\n%{http_code}' -X "$method" -H "Content-Type: application/json")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20")
  [ -n "$body" ] && args+=(--data "$body")
  "$CURL" "${args[@]}" "$url"
}

split_response() {
  # split_response <response>: sets RESP_BODY and RESP_CODE.
  RESP_CODE="${1##*$'\n'}"
  RESP_BODY="${1%$'\n'*}"
  [ "$RESP_BODY" != "$1" ] || RESP_BODY=""
}

# refresh_token <profile_dir>: refreshes the saved token pair in place.
# Prints nothing; returns 1 (with a reason on stderr) on failure. Only ever
# called for a non-active profile, so nothing else holds these tokens.
refresh_token() {
  local dir="$1" rt resp
  rt="$(json_read "$dir/login.json" | jq -r '.credentials.refreshToken // empty')"
  [ -n "$rt" ] || { echo "no refresh token saved" >&2; return 1; }
  resp="$(http POST "$TOKEN_URL" "" \
    "$(jq -nc --arg rt "$rt" --arg cid "$CLIENT_ID" '{grant_type:"refresh_token",refresh_token:$rt,client_id:$cid}')")" \
    || { echo "request failed" >&2; return 1; }
  split_response "$resp"
  [ "$RESP_CODE" = "200" ] || { echo "HTTP $RESP_CODE" >&2; return 1; }
  [ "$(echo "$RESP_BODY" | jq -r '.access_token // empty')" ] || { echo "no access_token in response" >&2; return 1; }
  # Keep the old refresh token if the server didn't rotate it.
  json_read "$dir/login.json" \
    | jq --argjson r "$RESP_BODY" --argjson now "$NOW" '
        .credentials.accessToken = $r.access_token
        | .credentials.refreshToken = ($r.refresh_token // .credentials.refreshToken)
        | .credentials.expiresAt = (($now + ($r.expires_in // 3600)) * 1000)
        | .savedAt = ($now | todate)' \
    | json_write_atomic "$dir/login.json"
}

# --- rendering ---------------------------------------------------------------

bar() {
  # bar <pct>: 10 cells, █ per full 10%, ▌ for a half cell, spaces after.
  # Cells are counted, never measured with ${#out}: under LC_CTYPE=C each █ is
  # three bytes, and a byte count would cut the bar short.
  local pct="${1%.*}" full half i cells out=""
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0
  full=$((pct / 10)); half=$(( (pct % 10) >= 5 ? 1 : 0 ))
  [ "$full" -eq "$BAR_WIDTH" ] && half=0
  for ((i = 0; i < full; i++)); do out+="█"; done
  [ "$half" -eq 1 ] && out+="▌"
  cells=$((full + half))
  for ((i = cells; i < BAR_WIDTH; i++)); do out+=" "; done
  printf '[%s]' "$out"
}

# iso_to_epoch <iso8601>: prints epoch seconds, or fails. Parsed with jq rather
# than date, because `date -d` is GNU-only and `date -j -f` is BSD-only while jq
# (already a hard dependency) behaves the same on both. Fractional seconds are
# dropped and a ±HH:MM offset normalised to Z, neither of which
# fromdateiso8601 accepts.
iso_to_epoch() {
  jq -rn --arg s "$1" '
    $s
    | sub("\\.[0-9]+"; "")
    | sub("(?<h>[+-][0-9]{2}):(?<m>[0-9]{2})$"; "\(.h)\(.m)")
    | if test("Z$") then fromdateiso8601
      elif test("[+-][0-9]{4}$") then
        (.[0:19] + "Z" | fromdateiso8601) as $t
        | (.[19:20] + "1" | tonumber) as $sign
        | ((.[20:22] | tonumber) * 3600 + (.[22:24] | tonumber) * 60) as $off
        | $t - ($sign * $off)
      else (. + "Z" | fromdateiso8601) end
    | floor' 2>/dev/null
}

# fmt_epoch <epoch> <strftime fmt>: GNU date spells this `-d @N`, BSD `-r N`.
# Probe once and remember; never branch on uname.
_DATE_KIND=""
fmt_epoch() {
  if [ -z "$_DATE_KIND" ]; then
    if date -d @0 +%s >/dev/null 2>&1; then _DATE_KIND=gnu; else _DATE_KIND=bsd; fi
  fi
  if [ "$_DATE_KIND" = gnu ]; then date -d "@$1" "+$2"; else date -r "$1" "+$2"; fi
}

fmt_reset() {
  # fmt_reset <iso8601>: "8:10pm" if within 24h, else "Thu 1pm". Empty in → empty out.
  # %p, not GNU's %P: BSD strftime prints a bare "P" for %P, so lowercase in bash.
  local iso="$1" epoch s
  [ -n "$iso" ] && [ "$iso" != "null" ] || return 0
  epoch="$(iso_to_epoch "$iso")" || true
  [[ "$epoch" =~ ^-?[0-9]+$ ]] || { echo "$iso"; return 0; }
  if [ $((epoch - NOW)) -lt 86400 ]; then s="$(fmt_epoch "$epoch" '%-I:%M%p')"
  else s="$(fmt_epoch "$epoch" '%a %-I:%M%p')"; fi
  s="${s/AM/am}"; s="${s/PM/pm}"   # only the meridiem: %a must keep its capital
  echo "${s/:00/}"
}

label_for() {
  # label_for <kind> <model display name>
  case "$1" in
    session)       echo "5h session" ;;
    weekly_all)    echo "7d all models" ;;
    weekly_scoped) echo "7d ${2:-scoped}" ;;
    *)             echo "$1" ;;
  esac
}

render_usage() {
  # render_usage <usage json>: one indented line per limit, plus extra usage.
  local json="$1" kind model pct resets label
  # Split on \x1f, not tab: tab is IFS whitespace, so `read` would collapse the
  # empty model field for unscoped limits into its neighbour.
  while IFS=$'\x1f' read -r kind model pct resets; do
    [ -n "$kind" ] || continue
    label="$(label_for "$kind" "$model")"
    printf '    %-15s %s %3d%%' "$label" "$(bar "$pct")" "${pct%.*}"
    resets="$(fmt_reset "$resets")"
    [ -n "$resets" ] && printf '  resets %s' "$resets"
    printf '\n'
  done < <(echo "$json" | jq -r '
    (.limits // [])[]
    | [.kind, (.scope.model.display_name // ""), (.percent // 0), (.resets_at // "")]
    | map(tostring) | join("\u001f")')
  # `|| true`: no extra usage means jq prints nothing and read returns 1, which
  # under set -e would abort the whole batch mid-render.
  local used="" limit=""
  read -r used limit < <(echo "$json" | jq -r '
    .extra_usage // empty
    | select(.is_enabled == true)
    | (pow(10; (.decimal_places // 2))) as $d
    | "\(.used_credits / $d) \(.monthly_limit / $d)"') || true
  if [ -n "${used:-}" ]; then
    printf '    %-15s $%.2f of $%.2f\n' "extra usage" "$used" "$limit"
  fi
}

# --- main --------------------------------------------------------------------

if [ ${#NAMES[@]} -eq 0 ]; then
  while read -r n; do [ -n "$n" ] && NAMES+=("$n"); done < <(profile_list)
fi
[ ${#NAMES[@]} -gt 0 ] || { echo "no saved profiles (save the current login with: cswap add <name>)" >&2; exit 1; }

CUR="$(active_profile)"
OK=0
FAILED=0

for name in "${NAMES[@]}"; do
  if ! profile_exists "$name"; then
    echo "$name: no such profile" >&2; FAILED=$((FAILED+1)); continue
  fi
  mark=" "; [ "$name" = "$CUR" ] && mark="●"
  printf '%s %s   %s · %s\n' "$mark" "$name" "$(profile_email "$name")" "$(profile_org "$name")"

  dir="$(profile_dir "$name")"
  if [ "$name" = "$CUR" ]; then
    creds="$(creds_read | jq '.claudeAiOauth // {}')"
  else
    creds="$(json_read "$dir/login.json" | jq '.credentials // {}')"
  fi
  token="$(echo "$creds" | jq -r '.accessToken // empty')"
  expires="$(echo "$creds" | jq -r '(.expiresAt // 0) / 1000 | floor')"

  if [ -z "$token" ]; then
    echo "    no token saved"; FAILED=$((FAILED+1)); continue
  fi
  if [ "$expires" -le "$NOW" ]; then
    if [ "$name" = "$CUR" ]; then
      echo "    token expired (open claude to refresh)"; FAILED=$((FAILED+1)); continue
    elif [ "$NO_REFRESH" -eq 1 ]; then
      echo "    token expired (run without --no-refresh)"; FAILED=$((FAILED+1)); continue
    fi
    if ! err="$(refresh_token "$dir" 2>&1)"; then
      echo "    token refresh failed: $err (switch to it and run claude to re-login)"; FAILED=$((FAILED+1)); continue
    fi
    token="$(json_read "$dir/login.json" | jq -r '.credentials.accessToken')"
  fi

  if ! resp="$(http GET "$USAGE_URL" "$token")"; then
    echo "    request failed"; FAILED=$((FAILED+1)); continue
  fi
  split_response "$resp"
  case "$RESP_CODE" in
    200) render_usage "$RESP_BODY"; OK=$((OK+1)) ;;
    401) echo "    token rejected (switch to it and run claude to re-login)"; FAILED=$((FAILED+1)) ;;
    *)   echo "    HTTP $RESP_CODE"; FAILED=$((FAILED+1)) ;;
  esac
done

[ "$OK" -gt 0 ] || exit 1
