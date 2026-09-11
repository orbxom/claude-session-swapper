#!/usr/bin/env bash
# cswap-limits.test.sh — tests for cswap-limits.sh. Runs every test_* function in this file.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$HERE/cswap-limits.sh"
source "$HERE/cswap-lib.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

# --- assertion helpers -------------------------------------------------------

assert_eq() {
  local actual="$1" expected="$2" label="${3:-}"
  if [ "$actual" = "$expected" ]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected: $expected"
  echo "       got:      $actual"
  return 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected to contain: $needle"
  echo "       got:                  $haystack"
  return 1
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected NOT to contain: $needle"
  echo "       got:                      $haystack"
  return 1
}

assert_exit_code() {
  local got="$1" expected="$2" label="${3:-}"
  if [ "$got" = "$expected" ]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected exit $expected, got $got"
  return 1
}

# --- fixtures ----------------------------------------------------------------

# file_mode <path>: the octal mode, from BSD stat or GNU stat. `stat -c` is
# GNU-only and `stat -f` BSD-only, so try one and fall back to the other.
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }


# Fixed clock: 2026-09-08T21:00:00Z. Session resets 4h10m later (same day in
# the 24h window); weekly resets in ~2 days.
FIXED_NOW=1788901200
EXP_FUTURE_MS=$(( (FIXED_NOW + 3600) * 1000 ))
EXP_PAST_MS=$(( (FIXED_NOW - 3600) * 1000 ))

new_sandbox() {
  SANDBOX="$(mktemp -d)"
  export CSWAP_HOME="$SANDBOX/cswap" CLAUDE_CONFIG_DIR="$SANDBOX/claude" CSWAP_NOW="$FIXED_NOW"
  export CSWAP_CREDS_STORE=file   # never reach for the real keychain in tests
  export CSWAP_DESKTOP_DIR="$SANDBOX/desktop" CSWAP_DESKTOP_RUNNING=0   # no desktop app unless a test makes one
  export CSWAP_CURL="$SANDBOX/curl" CURL_LOG="$SANDBOX/curl.log" TZ=UTC
  mkdir -p "$CLAUDE_CONFIG_DIR"
  : > "$CURL_LOG"
  make_stub_curl
}

# sandboxed_or_die: hard stop if a fixture is about to write outside SANDBOX.
# The first run of this suite had a fixture run in $(...), lost its exports,
# and captured real tokens into ~/.config/cswap. Never again.
sandboxed_or_die() {
  [ -n "${SANDBOX:-}" ] && [[ "${CLAUDE_CONFIG_DIR:-}" == "$SANDBOX"/* ]] && [[ "${CSWAP_HOME:-}" == "$SANDBOX"/* ]] \
    || { echo "refusing to run: fixtures not sandboxed (CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-unset})" >&2; exit 99; }
}

# make_live <uuid> <email> <expiresAt ms>
make_live() {
  sandboxed_or_die
  local uuid="$1" email="$2" exp="$3"
  cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"at-$uuid","refreshToken":"rt-$uuid","expiresAt":$exp}}
EOF
  cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<EOF
{"oauthAccount":{"accountUuid":"$uuid","emailAddress":"$email","organizationName":"Org $uuid"},"userID":"uid-$uuid"}
EOF
}

# make_profile <name> <uuid> <email> <expiresAt ms>: write a saved profile directly.
make_profile() {
  sandboxed_or_die
  local name="$1" uuid="$2" email="$3" exp="$4"
  mkdir -p "$CSWAP_HOME/profiles/$name"
  cat > "$CSWAP_HOME/profiles/$name/login.json" <<EOF
{"credentials":{"accessToken":"at-$uuid","refreshToken":"rt-$uuid","expiresAt":$exp},
 "account":{"accountUuid":"$uuid","emailAddress":"$email","organizationName":"Org $uuid"},"userID":"uid-$uuid"}
EOF
}

USAGE_JSON='{
  "five_hour": {"utilization": 85.0},
  "limits": [
    {"kind":"session","group":"session","percent":85,"severity":"warning","resets_at":"2026-09-09T01:10:00.073810+00:00","scope":null,"is_active":true},
    {"kind":"weekly_all","group":"weekly","percent":46,"severity":"normal","resets_at":"2026-09-10T18:00:00.073830+00:00","scope":null,"is_active":false},
    {"kind":"weekly_scoped","group":"weekly","percent":78,"severity":"warning","resets_at":"2026-09-10T18:00:00.073830+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
  ],
  "extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 593.0, "utilization": 5.93, "currency": "USD", "decimal_places": 2}
}'

# The stub answers by URL and bearer token. Behaviour per token:
#   at-bad*   -> 401
#   at-err*   -> 500
#   at-*      -> 200 with USAGE_JSON
# The refresh endpoint returns a new pair unless STUB_REFRESH_FAIL=1.
make_stub_curl() {
  cat > "$CSWAP_CURL" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
token=""; data=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -H) [[ "${args[i+1]}" == "Authorization: Bearer "* ]] && token="${args[i+1]#Authorization: Bearer }" ;;
    --data) data="${args[i+1]}" ;;
  esac
done
echo "$url token=$token data=$data" >> "$CURL_LOG"
case "$url" in
  *"/oauth/usage")
    case "$token" in
      at-bad*) printf '{"error":"unauthorized"}\n401' ;;
      at-err*) printf 'boom\n500' ;;
      at-*)    printf '%s\n200' "$USAGE_JSON" ;;
      *)       printf 'no token\n401' ;;
    esac ;;
  *"/oauth/token")
    if [ "${STUB_REFRESH_FAIL:-0}" = 1 ]; then printf '{"error":"invalid_grant"}\n400'
    else printf '{"access_token":"at-refreshed","refresh_token":"rt-refreshed","expires_in":28800,"token_type":"Bearer"}\n200'; fi ;;
  *) printf 'no route\n404' ;;
esac
EOF
  chmod +x "$CSWAP_CURL"
  export USAGE_JSON
}

run() {
  local o e
  o="$(mktemp)"; e="$(mktemp)"
  "$SCRIPT_UNDER_TEST" "$@" >"$o" 2>"$e" </dev/null; RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

# --- tests -------------------------------------------------------------------

test_help_and_bad_args() {
  run --help
  assert_exit_code "$RC" 0 || return 1
  assert_contains "$OUT" "Usage: cswap-limits.sh" || return 1
  run --bogus
  assert_exit_code "$RC" 2 || return 1
  run "bad name"
  assert_exit_code "$RC" 2 || return 1
}

test_no_profiles_exits_1() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  run
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "no saved profiles" || return 1
}

test_renders_active_profile_from_live_token() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com "$EXP_FUTURE_MS"
  make_profile work u1 one@example.com "$EXP_PAST_MS"   # stale stash; live must win
  run
  assert_exit_code "$RC" 0 || return 1
  local expected
  expected='● work   one@example.com · Org u1
    5h session      [████████▌ ]  85%  resets 1:10am
    7d all models   [████▌     ]  46%  resets Thu 6pm
    7d Fable        [███████▌  ]  78%  resets Thu 6pm
    extra usage     $5.93 of $100.00'
  assert_eq "$OUT" "$expected" || return 1
  assert_contains "$(cat "$CURL_LOG")" "token=at-u1" "live token used" || return 1
  assert_not_contains "$(cat "$CURL_LOG")" "/oauth/token" "no refresh for active" || return 1
}

test_expired_stashed_token_is_refreshed_and_written_back() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com "$EXP_FUTURE_MS"
  make_profile work u1 one@example.com "$EXP_FUTURE_MS"
  make_profile personal u2 two@example.com "$EXP_PAST_MS"
  run personal
  assert_exit_code "$RC" 0 || return 1
  assert_contains "$OUT" "  personal   two@example.com" || return 1
  assert_contains "$OUT" "5h session" || return 1
  local log; log="$(cat "$CURL_LOG")"
  assert_contains "$log" '/oauth/token token= data={"grant_type":"refresh_token","refresh_token":"rt-u2","client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}' "refresh request" || return 1
  assert_contains "$log" "/oauth/usage token=at-refreshed" "new token used" || return 1
  local f="$CSWAP_HOME/profiles/personal/login.json"
  assert_eq "$(jq -r .credentials.accessToken "$f")" "at-refreshed" || return 1
  assert_eq "$(jq -r .credentials.refreshToken "$f")" "rt-refreshed" || return 1
  assert_eq "$(jq -r .credentials.expiresAt "$f")" "$(( (FIXED_NOW + 28800) * 1000 ))" "expiresAt" || return 1
  assert_eq "$(jq -r .account.accountUuid "$f")" "u2" "account kept" || return 1
  assert_eq "$(file_mode "$f")" "600" || return 1
}

test_expired_active_token_is_not_refreshed() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com "$EXP_PAST_MS"
  make_profile work u1 one@example.com "$EXP_PAST_MS"
  run
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$OUT" "token expired (open claude to refresh)" || return 1
  assert_eq "$(cat "$CURL_LOG")" "" "no network calls" || return 1
  assert_eq "$(jq -r .claudeAiOauth.accessToken "$CLAUDE_CONFIG_DIR/.credentials.json")" "at-u1" "live untouched" || return 1
}

test_no_refresh_flag_reports_expired() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com "$EXP_FUTURE_MS"
  make_profile personal u2 two@example.com "$EXP_PAST_MS"
  run --no-refresh personal
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$OUT" "token expired (run without --no-refresh)" || return 1
  assert_eq "$(cat "$CURL_LOG")" "" "no network calls" || return 1
}

test_refresh_failure_is_reported_and_stash_untouched() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_profile personal u2 two@example.com "$EXP_PAST_MS"
  export STUB_REFRESH_FAIL=1
  run personal
  unset STUB_REFRESH_FAIL
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$OUT" "token refresh failed: HTTP 400" || return 1
  assert_eq "$(jq -r .credentials.refreshToken "$CSWAP_HOME/profiles/personal/login.json")" "rt-u2" || return 1
}

test_401_and_500_are_reported_per_profile_and_batch_continues() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com "$EXP_FUTURE_MS"
  make_profile a-bad bad1 a@example.com "$EXP_FUTURE_MS"
  make_profile b-err err1 b@example.com "$EXP_FUTURE_MS"
  make_profile c-ok u1 one@example.com "$EXP_FUTURE_MS"
  run
  assert_exit_code "$RC" 0 "one succeeded" || return 1
  assert_contains "$OUT" $'  a-bad   a@example.com · Org bad1\n    token rejected' || return 1
  assert_contains "$OUT" $'  b-err   b@example.com · Org err1\n    HTTP 500' || return 1
  assert_contains "$OUT" $'● c-ok   one@example.com · Org u1\n    5h session' || return 1
}

test_all_failed_exits_1_and_unknown_name_on_stderr() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_profile a-bad bad1 a@example.com "$EXP_FUTURE_MS"
  run a-bad nope
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "nope: no such profile" || return 1
}

test_bar_widths() {
  # Source the functions without running main: extract them with sed.
  eval "$(sed -n '/^bar() {/,/^}/p' "$SCRIPT_UNDER_TEST")"
  BAR_WIDTH=10
  assert_eq "$(bar 0)"   "[          ]" "0"   || return 1
  assert_eq "$(bar 5)"   "[▌         ]" "5"   || return 1
  assert_eq "$(bar 46)"  "[████▌     ]" "46"  || return 1
  assert_eq "$(bar 85)"  "[████████▌ ]" "85"  || return 1
  assert_eq "$(bar 100)" "[██████████]" "100" || return 1
  assert_eq "$(bar 78.4)" "[███████▌  ]" "78.4 (half cell)" || return 1
}

test_label_mapping() {
  eval "$(sed -n '/^label_for() {/,/^}/p' "$SCRIPT_UNDER_TEST")"
  assert_eq "$(label_for session "")" "5h session" || return 1
  assert_eq "$(label_for weekly_all "")" "7d all models" || return 1
  assert_eq "$(label_for weekly_scoped Opus)" "7d Opus" || return 1
  assert_eq "$(label_for weekly_scoped "")" "7d scoped" || return 1
  assert_eq "$(label_for something_new "")" "something_new" || return 1
}

test_fmt_reset_formats() {
  # Reset times used to come out as raw ISO on any BSD userland: fmt_reset asked
  # GNU `date -d`, and even with BSD's `date -r` the %P (lowercase am/pm) in the
  # format string is a GNU extension. Pin both shapes.
  eval "$(sed -n '/^iso_to_epoch() {/,/^}/p;/^_DATE_KIND=/p;/^fmt_epoch() {/,/^}/p;/^fmt_reset() {/,/^}/p' "$SCRIPT_UNDER_TEST")"
  local NOW="$FIXED_NOW" TZ=UTC
  export TZ
  assert_eq "$(fmt_reset '2026-09-09T01:10:00.073810+00:00')" "1:10am" "within 24h" || return 1
  assert_eq "$(fmt_reset '2026-09-10T18:00:00.073830+00:00')" "Thu 6pm" "beyond 24h" || return 1
  assert_eq "$(fmt_reset '2026-09-09T01:10:00Z')" "1:10am" "plain Z" || return 1
  assert_eq "$(fmt_reset '2026-09-09T11:10:00+10:00')" "1:10am" "non-UTC offset" || return 1
  assert_eq "$(fmt_reset '')" "" "empty in, empty out" || return 1
  assert_eq "$(fmt_reset 'null')" "" "null in, empty out" || return 1
  assert_eq "$(fmt_reset 'not-a-date')" "not-a-date" "unparseable falls through" || return 1
}

test_renders_when_extra_usage_disabled() {
  # An account without extra usage makes the jq query print nothing, `read`
  # return 1 and, under set -e, the whole batch die after the first profile.
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_profile a-one u1 one@example.com "$EXP_FUTURE_MS"
  make_profile b-two u2 two@example.com "$EXP_FUTURE_MS"
  # Prefix assignment, not export: the stub curl reads USAGE_JSON from the
  # environment, and this must not leak into the next test's stub.
  USAGE_JSON='{"limits":[{"kind":"session","percent":85,"resets_at":"2026-09-09T01:10:00.073810+00:00","scope":null}],"extra_usage":{"is_enabled":false}}' run
  assert_exit_code "$RC" 0 || return 1
  assert_contains "$OUT" "5h session" "limits still render" || return 1
  assert_not_contains "$OUT" "extra usage" "no extra usage line" || return 1
  assert_contains "$OUT" "b-two   two@example.com" "batch did not stop at the first profile" || return 1
}

test_bar_width_is_locale_independent() {
  # ${#out} counts bytes under LC_CTYPE=C, and each block glyph is three of
  # them, so a byte-measured bar came out a third of its width.
  local out
  out="$(LC_ALL=C bash -c "BAR_WIDTH=10; $(sed -n '/^bar() {/,/^}/p' "$SCRIPT_UNDER_TEST"); bar 46")"
  assert_eq "$out" "[████▌     ]" "C locale" || return 1
}

# --- runner ------------------------------------------------------------------

run_all_tests() {
  local fn
  while read -r fn; do
    echo "--- $fn"
    if "$fn"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("$fn"); fi
  done < <(declare -F | awk '{print $3}' | grep "^test_${1:-}" | sort)
  echo
  echo "Passed: $PASS  Failed: $FAIL"
  if [ "$FAIL" -gt 0 ]; then printf '  - %s\n' "${FAILED_TESTS[@]}"; return 1; fi
}

run_all_tests "$@"
