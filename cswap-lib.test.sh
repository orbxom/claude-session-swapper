#!/usr/bin/env bash
# cswap-lib.test.sh — tests for cswap-lib.sh. Runs every test_* function in this file.
set -u

LIB="$(cd "$(dirname "$0")" && pwd)/cswap-lib.sh"
source "$LIB"

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

assert_exit_code() {
  local got="$1" expected="$2" label="${3:-}"
  if [ "$got" = "$expected" ]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected exit $expected, got $got"
  return 1
}

# --- fixtures ----------------------------------------------------------------

# new_sandbox: temp CSWAP_HOME + CLAUDE_CONFIG_DIR in SANDBOX. Runs in the
# caller's shell (not $(...)) so the exports stick; caller traps cleanup.
new_sandbox() {
  SANDBOX="$(mktemp -d)"
  export CSWAP_HOME="$SANDBOX/cswap" CLAUDE_CONFIG_DIR="$SANDBOX/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
}

# sandboxed_or_die: hard stop if a fixture is about to write outside SANDBOX.
# The first run of this suite had a fixture run in $(...), lost its exports,
# and captured real tokens into ~/.config/cswap. Never again.
sandboxed_or_die() {
  [ -n "${SANDBOX:-}" ] && [[ "${CLAUDE_CONFIG_DIR:-}" == "$SANDBOX"/* ]] && [[ "${CSWAP_HOME:-}" == "$SANDBOX"/* ]] \
    || { echo "refusing to run: fixtures not sandboxed (CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-unset})" >&2; exit 99; }
}

# make_live <uuid> <email> [<refresh>]: write live credential files that carry
# unrelated keys too, so tests can prove those keys survive a restore.
make_live() {
  sandboxed_or_die
  local uuid="$1" email="$2" refresh="${3:-rt-$1}"
  cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"at-$uuid","refreshToken":"$refresh","expiresAt":1,"scopes":["user:inference"],"subscriptionType":"team"},
 "mcpOAuth":{"plugin:slack|abc":{"accessToken":"slack-token"}}}
EOF
  cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<EOF
{"numStartups":42,"projects":{"/x":{"allowedTools":[]}},
 "oauthAccount":{"accountUuid":"$uuid","emailAddress":"$email","organizationName":"Org $uuid"},
 "userID":"uid-$uuid"}
EOF
}

make_logged_out() {
  sandboxed_or_die
  echo '{"mcpOAuth":{"plugin:slack|abc":{"accessToken":"slack-token"}}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
  echo '{"numStartups":42}' > "$CLAUDE_CONFIG_DIR/.claude.json"
}

# --- tests -------------------------------------------------------------------

test_paths_follow_claude_config_dir() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  assert_eq "$(creds_file)" "$CLAUDE_CONFIG_DIR/.credentials.json" "creds" || return 1
  assert_eq "$(claude_json_file)" "$CLAUDE_CONFIG_DIR/.claude.json" "claude.json" || return 1
  assert_eq "$(profiles_dir)" "$CSWAP_HOME/profiles" "profiles" || return 1
}

test_paths_default_to_home() {
  local out
  out="$(unset CLAUDE_CONFIG_DIR CSWAP_HOME XDG_CONFIG_HOME; HOME=/h; claude_json_file; creds_file; cswap_home)"
  assert_eq "$out" $'/h/.claude.json\n/h/.claude/.credentials.json\n/h/.config/cswap' || return 1
}

test_json_read_missing_is_empty_object() {
  assert_eq "$(json_read /nonexistent/file.json)" "{}" || return 1
}

test_json_write_atomic_sets_mode_600() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  echo '{"a":1}' | json_write_atomic "$SANDBOX/sub/out.json"
  assert_eq "$(stat -c %a "$SANDBOX/sub/out.json")" "600" "mode" || return 1
  assert_eq "$(jq -c . "$SANDBOX/sub/out.json")" '{"a":1}' "content" || return 1
  assert_eq "$(ls -A "$SANDBOX/sub" | wc -l)" "1" "no temp left behind" || return 1
}

test_identity_empty_when_logged_out() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_logged_out
  assert_eq "$(slot_login_identity)" "" || return 1
  assert_eq "$(active_profile)" "" || return 1
}

test_capture_writes_login_json() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  capture_all work || return 1
  local f="$CSWAP_HOME/profiles/work/login.json"
  assert_eq "$(stat -c %a "$f")" "600" "mode" || return 1
  assert_eq "$(stat -c %a "$CSWAP_HOME/profiles/work")" "700" "dir mode" || return 1
  assert_eq "$(jq -r '.credentials.accessToken' "$f")" "at-u1" "token" || return 1
  assert_eq "$(jq -r '.account.emailAddress' "$f")" "one@example.com" "email" || return 1
  assert_eq "$(jq -r '.userID' "$f")" "uid-u1" "userID" || return 1
  assert_eq "$(jq -r '.savedAt | test("^[0-9]{4}-")' "$f")" "true" "savedAt" || return 1
  assert_eq "$(jq -r 'has("mcpOAuth")' "$f")" "false" "mcp tokens not captured" || return 1
}

test_capture_fails_when_logged_out() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_logged_out
  local rc=0; capture_all work 2>/dev/null || rc=$?
  assert_exit_code "$rc" 1 || return 1
  [ ! -e "$CSWAP_HOME/profiles/work/login.json" ] || { echo "  FAIL wrote a profile while logged out"; return 1; }
}

test_restore_replaces_login_and_preserves_other_keys() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  capture_all personal || return 1
  make_live u2 two@example.com
  restore_all personal || return 1
  local creds="$CLAUDE_CONFIG_DIR/.credentials.json" cj="$CLAUDE_CONFIG_DIR/.claude.json"
  assert_eq "$(jq -r '.claudeAiOauth.accessToken' "$creds")" "at-u1" "token restored" || return 1
  assert_eq "$(jq -r '.mcpOAuth["plugin:slack|abc"].accessToken' "$creds")" "slack-token" "mcp kept" || return 1
  assert_eq "$(jq -r '.oauthAccount.emailAddress' "$cj")" "one@example.com" "account restored" || return 1
  assert_eq "$(jq -r '.userID' "$cj")" "uid-u1" "userID restored" || return 1
  assert_eq "$(jq -r '.numStartups' "$cj")" "42" "other keys kept" || return 1
  assert_eq "$(jq -c '.projects' "$cj")" '{"/x":{"allowedTools":[]}}' "projects kept" || return 1
  assert_eq "$(stat -c %a "$creds")" "600" "creds mode" || return 1
}

test_restore_into_missing_live_files_creates_them() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  capture_all personal || return 1
  rm "$CLAUDE_CONFIG_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"
  restore_all personal || return 1
  assert_eq "$(slot_login_identity)" "u1" || return 1
}

test_restore_fails_on_empty_profile() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  mkdir -p "$CSWAP_HOME/profiles/broken"
  local rc=0; restore_all broken 2>/dev/null || rc=$?
  assert_exit_code "$rc" 1 || return 1
  assert_eq "$(slot_login_identity)" "u1" "live untouched" || return 1
}

test_active_profile_matches_by_uuid() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; capture_all alpha || return 1
  make_live u2 two@example.com; capture_all beta || return 1
  assert_eq "$(active_profile)" "beta" "beta live" || return 1
  make_live u1 one@example.com
  assert_eq "$(active_profile)" "alpha" "alpha live" || return 1
  make_live u3 three@example.com
  assert_eq "$(active_profile)" "" "unsaved" || return 1
}

test_profile_list_sorted_and_empty_ok() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  assert_eq "$(profile_list)" "" "no dir" || return 1
  make_live u1 one@example.com
  capture_all zeta; capture_all alpha
  assert_eq "$(profile_list | tr '\n' ' ')" "alpha zeta " || return 1
  assert_eq "$(profile_email alpha)" "one@example.com" || return 1
  assert_eq "$(profile_org alpha)" "Org u1" || return 1
}

test_valid_profile_name() {
  valid_profile_name "work-1_A" || { echo "  FAIL rejected valid name"; return 1; }
  valid_profile_name "../x" && { echo "  FAIL accepted ../x"; return 1; }
  valid_profile_name "a b" && { echo "  FAIL accepted space"; return 1; }
  valid_profile_name "" && { echo "  FAIL accepted empty"; return 1; }
  return 0
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
