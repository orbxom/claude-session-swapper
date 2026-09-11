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

# file_mode <path>: the octal mode, from BSD stat or GNU stat. `stat -c` is
# GNU-only and `stat -f` BSD-only, so try one and fall back to the other.
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }


# new_sandbox: temp CSWAP_HOME + CLAUDE_CONFIG_DIR in SANDBOX. Runs in the
# caller's shell (not $(...)) so the exports stick; caller traps cleanup.
new_sandbox() {
  SANDBOX="$(mktemp -d)"
  export CSWAP_HOME="$SANDBOX/cswap" CLAUDE_CONFIG_DIR="$SANDBOX/claude"
  export CSWAP_CREDS_STORE=file   # keychain backend has its own tests below
  export CSWAP_DESKTOP_DIR="$SANDBOX/desktop" CSWAP_DESKTOP_RUNNING=0   # no desktop app unless a test makes one
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
  assert_eq "$(file_mode "$SANDBOX/sub/out.json")" "600" "mode" || return 1
  assert_eq "$(jq -c . "$SANDBOX/sub/out.json")" '{"a":1}' "content" || return 1
  assert_eq "$(ls -A "$SANDBOX/sub" | wc -l | tr -d '[:space:]')" "1" "no temp left behind" || return 1
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
  assert_eq "$(file_mode "$f")" "600" "mode" || return 1
  assert_eq "$(file_mode "$CSWAP_HOME/profiles/work")" "700" "dir mode" || return 1
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
  assert_eq "$(file_mode "$creds")" "600" "creds mode" || return 1
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

# --- keychain store ----------------------------------------------------------

# use_stub_keychain: a fake `security` over a file in SANDBOX, speaking the two
# subcommands Claude Code (and so cswap) uses. Nothing here ever touches the
# real login keychain.
use_stub_keychain() {
  sandboxed_or_die
  unset CSWAP_CREDS_STORE
  export CSWAP_SECURITY="$SANDBOX/security" KEYCHAIN_DB="$SANDBOX/keychain"
  CSWAP_SECURITY_BIN="$CSWAP_SECURITY"
  _CREDS_STORE=""
  cat > "$CSWAP_SECURITY" <<'STUB'
#!/usr/bin/env bash
# item file is "$KEYCHAIN_DB.<service>"; absent file = no such item (exit 44).
cmd="$1"; shift
svc=""; acct=""; hex=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift 2 ;;
    -a) acct="$2"; shift 2 ;;
    -X) hex="$2"; shift 2 ;;
    -w|-U) shift ;;
    *) shift ;;
  esac
done
f="$KEYCHAIN_DB.$svc"
case "$cmd" in
  find-generic-password)
    [ -f "$f" ] || { echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44; }
    printf '%s' "$(cat "$f")" ;;
  add-generic-password)
    printf '%s' "$hex" | perl -ne 's/([0-9a-f]{2})/print chr hex $1/gie' > "$f" ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$CSWAP_SECURITY"
}

stub_keychain_put() { printf '%s' "$2" > "$KEYCHAIN_DB.$1"; }

test_keychain_service_name_follows_the_config_dir() {
  local plain hashed
  plain="$(unset CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR; keychain_service)"
  assert_eq "$plain" "Claude Code-credentials" "default install" || return 1
  hashed="$(unset CLAUDE_SECURESTORAGE_CONFIG_DIR; CLAUDE_CONFIG_DIR=/tmp/elsewhere keychain_service)"
  local want="Claude Code-credentials-$(printf '%s' /tmp/elsewhere | sha256_hex | cut -c1-8)"
  assert_eq "$hashed" "$want" "relocated install" || return 1
  assert_eq "$(CLAUDE_SECURESTORAGE_CONFIG_DIR= CLAUDE_CONFIG_DIR=/tmp/elsewhere keychain_service)" \
    "Claude Code-credentials" "empty securestorage dir wins" || return 1
}

test_keychain_account_falls_back_on_odd_usernames() {
  assert_eq "$(USER=ada.lovelace-1 keychain_account)" "ada.lovelace-1" "plain name" || return 1
  assert_eq "$(USER='a b' keychain_account)" "claude-code-user" "name with a space" || return 1
}

test_store_prefers_a_live_keychain_item_over_the_file() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  use_stub_keychain
  make_live u-file file@example.com          # a file exists...
  assert_eq "$(creds_store)" "file" "no keychain item yet" || return 1
  _CREDS_STORE=""
  stub_keychain_put "$(keychain_service)" '{"claudeAiOauth":{"accessToken":"at-kc"}}'
  assert_eq "$(creds_store)" "keychain" "keychain item wins" || return 1
  assert_eq "$(creds_read | jq -r '.claudeAiOauth.accessToken')" "at-kc" || return 1
}

test_store_is_keychain_when_logged_out_on_a_mac() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  use_stub_keychain
  rm -f "$(creds_file)"
  assert_eq "$(creds_store)" "keychain" || return 1
  assert_eq "$(creds_read)" "{}" "no item reads as empty" || return 1
}

test_capture_and_restore_through_the_keychain() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  use_stub_keychain
  local svc; svc="$(keychain_service)"
  # A keychain login that also carries MCP and trusted-device tokens.
  stub_keychain_put "$svc" '{"claudeAiOauth":{"accessToken":"at-u1","refreshToken":"rt-u1","expiresAt":1},"mcpOAuth":{"plugin:slack|abc":{"accessToken":"slack-token"}},"trustedDeviceToken":"tdt-1"}'
  cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<'EOF'
{"numStartups":42,"oauthAccount":{"accountUuid":"u1","emailAddress":"one@example.com","organizationName":"Org u1"},"userID":"uid-u1"}
EOF
  rm -f "$(creds_file)"
  capture_all personal || return 1
  assert_eq "$(jq -r '.credentials.accessToken' "$CSWAP_HOME/profiles/personal/login.json")" "at-u1" "captured from keychain" || return 1

  # a different account is live; restoring must put u1 back
  stub_keychain_put "$svc" '{"claudeAiOauth":{"accessToken":"at-u2"},"mcpOAuth":{"plugin:slack|abc":{"accessToken":"slack-token"}},"trustedDeviceToken":"tdt-1"}'
  _CREDS_STORE=""
  restore_all personal || return 1
  assert_eq "$(creds_read | jq -r '.claudeAiOauth.accessToken')" "at-u1" "token restored" || return 1
  assert_eq "$(creds_read | jq -r '.mcpOAuth["plugin:slack|abc"].accessToken')" "slack-token" "mcp tokens kept" || return 1
  assert_eq "$(creds_read | jq -r '.trustedDeviceToken')" "tdt-1" "trusted device token kept" || return 1
  assert_eq "$(slot_login_identity)" "u1" "account restored" || return 1
  [ ! -e "$(creds_file)" ] || { echo "  FAIL wrote a plaintext credentials file next to a keychain login"; return 1; }
}

test_capture_fails_when_the_keychain_has_no_login() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  use_stub_keychain
  stub_keychain_put "$(keychain_service)" '{"mcpOAuth":{}}'
  cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<'EOF'
{"numStartups":42}
EOF
  local rc=0; capture_all work 2>/dev/null || rc=$?
  assert_exit_code "$rc" 1 || return 1
  [ ! -e "$CSWAP_HOME/profiles/work/login.json" ] || { echo "  FAIL wrote a profile while logged out"; return 1; }
}

# --- slot: desktop -----------------------------------------------------------

# make_desktop <uuid> [<cookie payload>]: a stand-in for the Claude desktop
# app's data dir. The Cookies file is opaque to cswap (an encrypted SQLite DB
# in real life), so a plain string proves the round trip just as well.
make_desktop() {
  sandboxed_or_die
  local uuid="$1" cookie="${2:-cookie-$1}"
  mkdir -p "$CSWAP_DESKTOP_DIR"
  cat > "$CSWAP_DESKTOP_DIR/config.json" <<EOF
{"locale":"en-US","windowSizeWasSignedIn":true,
 "lastKnownAccountUuid":"$uuid",
 "oauth:tokenCache":"v10:tc-$uuid","oauth:tokenCacheV2":"v10:tc2-$uuid"}
EOF
  echo "{\"$uuid\":\"pk1:dev-$uuid\"}" > "$CSWAP_DESKTOP_DIR/ant-device-registry.json"
  printf '%s' "$cookie" > "$CSWAP_DESKTOP_DIR/Cookies"
}

test_desktop_slot_is_inert_without_the_app() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  assert_eq "$(slot_desktop_identity)" "" "no identity" || return 1
  capture_all solo || return 1
  [ ! -e "$CSWAP_HOME/profiles/solo/desktop.json" ] || { echo "  FAIL wrote desktop.json with no app"; return 1; }
  restore_all solo || return 1
  assert_eq "$(slot_login_identity)" "u1" "login still swapped" || return 1
}

test_desktop_capture_and_restore_round_trip() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; make_desktop u1 'cookie-blob-one'
  capture_all personal || return 1
  local f="$CSWAP_HOME/profiles/personal/desktop.json"
  assert_eq "$(file_mode "$f")" "600" "mode" || return 1
  assert_eq "$(jq -r '.accountUuid' "$f")" "u1" "uuid" || return 1
  assert_eq "$(jq -r '."config"."oauth:tokenCacheV2"' "$f")" "v10:tc2-u1" "token cache saved" || return 1

  # the app is now signed in as somebody else
  make_live u2 two@example.com; make_desktop u2 'cookie-blob-two'
  restore_all personal || return 1
  assert_eq "$(slot_desktop_identity)" "u1" "uuid restored" || return 1
  assert_eq "$(cat "$CSWAP_DESKTOP_DIR/Cookies")" "cookie-blob-one" "cookies restored" || return 1
  assert_eq "$(jq -r '."oauth:tokenCache"' "$CSWAP_DESKTOP_DIR/config.json")" "v10:tc-u1" "token cache restored" || return 1
  assert_eq "$(jq -r '.locale' "$CSWAP_DESKTOP_DIR/config.json")" "en-US" "other config keys kept" || return 1
  assert_eq "$(jq -r '.windowSizeWasSignedIn' "$CSWAP_DESKTOP_DIR/config.json")" "true" "other config keys kept" || return 1
  assert_eq "$(jq -r '.["u2"]' "$CSWAP_DESKTOP_DIR/ant-device-registry.json")" "pk1:dev-u2" "other accounts keep their registration" || return 1
  assert_eq "$(jq -r '.["u1"]' "$CSWAP_DESKTOP_DIR/ant-device-registry.json")" "pk1:dev-u1" "restored registration" || return 1
}

test_desktop_restore_clears_a_stale_cookie_journal() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; make_desktop u1
  capture_all personal || return 1
  make_desktop u2
  : > "$CSWAP_DESKTOP_DIR/Cookies-journal"
  : > "$CSWAP_DESKTOP_DIR/Cookies-wal"
  restore_all personal || return 1
  [ ! -e "$CSWAP_DESKTOP_DIR/Cookies-journal" ] || { echo "  FAIL left a journal that would replay the old login"; return 1; }
  [ ! -e "$CSWAP_DESKTOP_DIR/Cookies-wal" ] || { echo "  FAIL left a WAL"; return 1; }
}

test_desktop_capture_skips_an_app_never_signed_in() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  mkdir -p "$CSWAP_DESKTOP_DIR"
  echo '{"locale":"en-US"}' > "$CSWAP_DESKTOP_DIR/config.json"
  capture_all work || return 1
  [ ! -e "$CSWAP_HOME/profiles/work/desktop.json" ] || { echo "  FAIL saved a desktop login that does not exist"; return 1; }
}

test_desktop_restore_skips_a_profile_saved_without_it() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  capture_all old-profile || return 1          # saved before the app existed
  make_desktop u2
  restore_all old-profile || return 1
  assert_eq "$(slot_desktop_identity)" "u2" "desktop left alone" || return 1
  assert_eq "$(slot_login_identity)" "u1" "login still restored" || return 1
}

test_desktop_preflight_refuses_while_the_app_runs() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; make_desktop u1
  CSWAP_DESKTOP_RUNNING=0 preflight_all || { echo "  FAIL refused while the app was closed"; return 1; }
  local rc=0 err
  err="$(CSWAP_DESKTOP_RUNNING=1 preflight_all 2>&1)" || rc=$?
  assert_exit_code "$rc" 1 "refuses" || return 1
  assert_contains "$err" "quit it first" || return 1
  assert_contains "$err" "CSWAP_NO_DESKTOP" "offers the escape hatch" || return 1
  rc=0; CSWAP_DESKTOP_RUNNING=1 CSWAP_NO_DESKTOP=1 preflight_all 2>/dev/null || rc=$?
  assert_exit_code "$rc" 0 "CSWAP_NO_DESKTOP opts out" || return 1
}

test_slots_out_of_sync_reports_a_mismatched_desktop() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; make_desktop u1
  assert_eq "$(slots_out_of_sync)" "" "in sync" || return 1
  make_desktop u2
  assert_eq "$(slots_out_of_sync)" "desktop" "desktop on another account" || return 1
  make_logged_out
  assert_eq "$(slots_out_of_sync)" "" "nothing to compare when logged out" || return 1
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
