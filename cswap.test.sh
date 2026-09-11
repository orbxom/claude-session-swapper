#!/usr/bin/env bash
# cswap.test.sh — tests for cswap.sh. Runs every test_* function in this file.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$HERE/cswap.sh"
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

assert_exit_code() {
  local got="$1" expected="$2" label="${3:-}"
  if [ "$got" = "$expected" ]; then return 0; fi
  echo "  FAIL ${label:+($label) }expected exit $expected, got $got"
  return 1
}

# --- fixtures ----------------------------------------------------------------

new_sandbox() {
  SANDBOX="$(mktemp -d)"
  export CSWAP_HOME="$SANDBOX/cswap" CLAUDE_CONFIG_DIR="$SANDBOX/claude"
  export CSWAP_CREDS_STORE=file   # never reach for the real keychain in tests
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

make_live() {
  sandboxed_or_die
  local uuid="$1" email="$2" refresh="${3:-rt-$1}"
  cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"at-$uuid","refreshToken":"$refresh","expiresAt":1},
 "mcpOAuth":{"plugin:slack|abc":{"accessToken":"slack-token"}}}
EOF
  cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<EOF
{"numStartups":42,
 "oauthAccount":{"accountUuid":"$uuid","emailAddress":"$email","organizationName":"Org $uuid"},
 "userID":"uid-$uuid"}
EOF
}

make_logged_out() {
  sandboxed_or_die
  echo '{"mcpOAuth":{}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
  echo '{"numStartups":42}' > "$CLAUDE_CONFIG_DIR/.claude.json"
}

live_token()  { jq -r '.claudeAiOauth.accessToken // empty' "$CLAUDE_CONFIG_DIR/.credentials.json"; }
live_uuid()   { jq -r '.oauthAccount.accountUuid // empty' "$CLAUDE_CONFIG_DIR/.claude.json"; }
saved_field() { jq -r "$2" "$CSWAP_HOME/profiles/$1/login.json"; }

# run <args…>: runs the script, captures stdout in OUT, stderr in ERR, code in RC.
run() {
  local o e
  o="$(mktemp)"; e="$(mktemp)"
  "$SCRIPT_UNDER_TEST" "$@" >"$o" 2>"$e" </dev/null; RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

# --- tests: parsing ----------------------------------------------------------

test_help_exits_0() {
  run --help
  assert_exit_code "$RC" 0 || return 1
  assert_contains "$OUT" "Usage: cswap" || return 1
}

test_unknown_flag_exits_2() {
  run --bogus
  assert_exit_code "$RC" 2 || return 1
  assert_contains "$ERR" "unknown flag: --bogus" || return 1
}

test_bad_name_exits_2() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  run add "../evil"
  assert_exit_code "$RC" 2 || return 1
  assert_contains "$ERR" "invalid profile name" || return 1
  run "a b"
  assert_exit_code "$RC" 2 || return 1
}

test_extra_argument_exits_2() {
  run add one two
  assert_exit_code "$RC" 2 || return 1
  assert_contains "$ERR" "unexpected argument: two" || return 1
}

# --- tests: add / list / status ---------------------------------------------

test_add_then_list_marks_active() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  run add work
  assert_exit_code "$RC" 0 || return 1
  assert_contains "$ERR" "saved work (one@example.com)" || return 1
  assert_eq "$(saved_field work .credentials.accessToken)" "at-u1" || return 1
  run list
  assert_exit_code "$RC" 0 || return 1
  assert_contains "$OUT" "● work" "active marker" || return 1
  assert_contains "$OUT" "one@example.com" || return 1
  assert_contains "$OUT" "Org u1" || return 1
}

test_add_refuses_existing_without_force() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  run add work; assert_exit_code "$RC" 0 || return 1
  make_live u2 two@example.com
  run add work
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "already exists" || return 1
  assert_eq "$(saved_field work .account.accountUuid)" "u1" "unchanged" || return 1
  run add work --force
  assert_exit_code "$RC" 0 || return 1
  assert_eq "$(saved_field work .account.accountUuid)" "u2" "overwritten" || return 1
}

test_add_when_logged_out_fails() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_logged_out
  run add work
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "not logged in" || return 1
}

test_status_variants() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_logged_out
  run status
  assert_exit_code "$RC" 1 || return 1
  assert_eq "$OUT" "not logged in" || return 1
  make_live u1 one@example.com
  run status
  assert_exit_code "$RC" 0 || return 1
  assert_eq "$OUT" "unsaved login: one@example.com" || return 1
  run add work
  run status
  assert_eq "$OUT" "work (one@example.com)" || return 1
}

test_list_notes_unsaved_login_on_stderr() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; run add work
  make_live u9 nine@example.com
  run list
  assert_exit_code "$RC" 0 || return 1
  assert_contains "$OUT" "  work" || return 1
  [[ "$OUT" != *"●"* ]] || { echo "  FAIL nothing should be marked active"; return 1; }
  assert_contains "$ERR" "nine@example.com is not saved" || return 1
}

# --- tests: switch -----------------------------------------------------------

test_switch_saves_rotated_token_before_restoring() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; run add work
  make_live u2 two@example.com; run add personal
  # Simulate Claude Code rotating personal's refresh token while running.
  make_live u2 two@example.com rt-rotated
  run work
  assert_exit_code "$RC" 0 || return 1
  assert_contains "$ERR" "switched to work (one@example.com)" || return 1
  assert_eq "$(live_uuid)" "u1" "live is now work" || return 1
  assert_eq "$(live_token)" "at-u1" || return 1
  assert_eq "$(saved_field personal .credentials.refreshToken)" "rt-rotated" "rotated token saved" || return 1
  assert_eq "$(jq -r '.mcpOAuth["plugin:slack|abc"].accessToken' "$CLAUDE_CONFIG_DIR/.credentials.json")" "slack-token" "mcp kept" || return 1
}

test_switch_to_active_reports_already_on() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; run add work
  run work
  assert_exit_code "$RC" 0 || return 1
  assert_contains "$ERR" "already on work" || return 1
}

test_switch_refuses_unsaved_login_without_discard() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; run add work
  make_live u9 nine@example.com
  run work
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "current login (nine@example.com) is not saved" || return 1
  assert_eq "$(live_uuid)" "u9" "live untouched" || return 1
  run work --discard
  assert_exit_code "$RC" 0 || return 1
  assert_eq "$(live_uuid)" "u1" || return 1
  assert_eq "$(profile_list | wc -l | tr -d '[:space:]')" "1" "no profile created for the discarded login" || return 1
}

test_switch_when_logged_out_just_restores() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; run add work
  make_logged_out
  run work
  assert_exit_code "$RC" 0 || return 1
  assert_eq "$(live_uuid)" "u1" || return 1
  assert_eq "$(jq -r .numStartups "$CLAUDE_CONFIG_DIR/.claude.json")" "42" "other keys kept" || return 1
}

test_switch_unknown_profile_exits_1() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  run nope
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "no such profile: nope" || return 1
}

test_picker_with_no_profiles_exits_1() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com
  run
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "no saved profiles" || return 1
}

# --- tests: rm ---------------------------------------------------------------

test_rm_requires_confirmation_and_never_touches_live() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; run add work
  # stdin is /dev/null in run(): read hits EOF -> 130, profile kept.
  run rm work
  assert_exit_code "$RC" 130 || return 1
  [ -d "$CSWAP_HOME/profiles/work" ] || { echo "  FAIL deleted without confirmation"; return 1; }
  run rm work --yes
  assert_exit_code "$RC" 0 || return 1
  [ ! -d "$CSWAP_HOME/profiles/work" ] || { echo "  FAIL not deleted"; return 1; }
  assert_eq "$(live_uuid)" "u1" "live untouched" || return 1
  run rm work --yes
  assert_exit_code "$RC" 1 "missing profile" || return 1
}

test_rm_accepts_y_on_stdin() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; run add work
  local rc=0
  echo y | "$SCRIPT_UNDER_TEST" rm work 2>/dev/null || rc=$?
  assert_exit_code "$rc" 0 || return 1
  [ ! -d "$CSWAP_HOME/profiles/work" ] || { echo "  FAIL not deleted"; return 1; }
}

# --- tests: new (stub claude) -----------------------------------------------

# make_stub_claude: a fake `claude` whose `auth logout` empties the live login
# and whose `auth login` writes the fixture for STUB_LOGIN_UUID/EMAIL.
make_stub_claude() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "stub claude $*" >> "$STUB_LOG"
case "$1 $2" in
  "auth logout")
    jq 'del(.claudeAiOauth)' "$CLAUDE_CONFIG_DIR/.credentials.json" > "$CLAUDE_CONFIG_DIR/.c.tmp" && mv "$CLAUDE_CONFIG_DIR/.c.tmp" "$CLAUDE_CONFIG_DIR/.credentials.json"
    jq 'del(.oauthAccount)' "$CLAUDE_CONFIG_DIR/.claude.json" > "$CLAUDE_CONFIG_DIR/.j.tmp" && mv "$CLAUDE_CONFIG_DIR/.j.tmp" "$CLAUDE_CONFIG_DIR/.claude.json" ;;
  "auth login")
    [ "${STUB_LOGIN_FAIL:-0}" = 1 ] && exit 1
    jq --arg u "$STUB_LOGIN_UUID" '.claudeAiOauth = {accessToken: ("at-"+$u), refreshToken: ("rt-"+$u), expiresAt: 1}' "$CLAUDE_CONFIG_DIR/.credentials.json" > "$CLAUDE_CONFIG_DIR/.c.tmp" && mv "$CLAUDE_CONFIG_DIR/.c.tmp" "$CLAUDE_CONFIG_DIR/.credentials.json"
    jq --arg u "$STUB_LOGIN_UUID" --arg e "$STUB_LOGIN_EMAIL" '.oauthAccount = {accountUuid: $u, emailAddress: $e, organizationName: "New Org"} | .userID = ("uid-"+$u)' "$CLAUDE_CONFIG_DIR/.claude.json" > "$CLAUDE_CONFIG_DIR/.j.tmp" && mv "$CLAUDE_CONFIG_DIR/.j.tmp" "$CLAUDE_CONFIG_DIR/.claude.json" ;;
esac
EOF
  chmod +x "$SANDBOX/bin/claude"
  export STUB_LOG="$SANDBOX/stub.log"
  export PATH="$SANDBOX/bin:$PATH"
}

test_new_saves_current_logs_out_in_and_saves_new() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  local old_path="$PATH"
  make_stub_claude
  export STUB_LOGIN_UUID=u2 STUB_LOGIN_EMAIL=two@example.com
  make_live u1 one@example.com; run add work
  make_live u1 one@example.com rt-rotated
  run new personal
  export PATH="$old_path"
  assert_exit_code "$RC" 0 || return 1
  assert_contains "$ERR" "saved work (one@example.com)" "old saved first" || return 1
  assert_contains "$ERR" "saved personal (two@example.com)" || return 1
  assert_eq "$(saved_field work .credentials.refreshToken)" "rt-rotated" "rotated token saved" || return 1
  assert_eq "$(saved_field personal .account.accountUuid)" "u2" || return 1
  assert_eq "$(live_uuid)" "u2" || return 1
  assert_eq "$(cat "$STUB_LOG")" $'stub claude auth logout\nstub claude auth login' "call order" || return 1
}

test_new_skips_logout_when_already_logged_out() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  local old_path="$PATH"
  make_stub_claude
  export STUB_LOGIN_UUID=u2 STUB_LOGIN_EMAIL=two@example.com
  make_logged_out
  run new personal
  export PATH="$old_path"
  assert_exit_code "$RC" 0 || return 1
  assert_eq "$(cat "$STUB_LOG")" "stub claude auth login" || return 1
}

test_new_refuses_unsaved_login() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  local old_path="$PATH"
  make_stub_claude
  make_live u9 nine@example.com
  run new personal
  export PATH="$old_path"
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "is not saved" || return 1
  [ ! -e "$STUB_LOG" ] || { echo "  FAIL claude was invoked"; return 1; }
  assert_eq "$(live_uuid)" "u9" "live untouched" || return 1
}

test_new_reports_failed_login() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  local old_path="$PATH"
  make_stub_claude
  export STUB_LOGIN_FAIL=1
  make_live u1 one@example.com; run add work
  run new personal
  export PATH="$old_path"; unset STUB_LOGIN_FAIL
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "you are now logged out" || return 1
  [ ! -d "$CSWAP_HOME/profiles/personal" ] || { echo "  FAIL created profile after failed login"; return 1; }
  assert_eq "$(saved_field work .account.accountUuid)" "u1" "work still saved" || return 1
}

test_new_refuses_existing_name() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; run add work
  run new work
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "already exists" || return 1
}

test_switch_refuses_while_the_desktop_app_runs() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; run add work
  mkdir -p "$CSWAP_DESKTOP_DIR"
  echo '{"lastKnownAccountUuid":"u1"}' > "$CSWAP_DESKTOP_DIR/config.json"
  make_live u2 two@example.com; run add personal
  export CSWAP_DESKTOP_RUNNING=1
  run work
  assert_exit_code "$RC" 1 || return 1
  assert_contains "$ERR" "quit it first" || return 1
  assert_eq "$(live_uuid)" "u2" "live login untouched" || return 1
  # the escape hatch still switches the CLI
  CSWAP_NO_DESKTOP=1 run work
  assert_exit_code "$RC" 0 || return 1
  assert_eq "$(live_uuid)" "u1" "CLI switched with --no-desktop" || return 1
  unset CSWAP_DESKTOP_RUNNING
}

test_status_notes_a_desktop_on_another_account() {
  new_sandbox; trap "rm -rf '$SANDBOX'" RETURN
  make_live u1 one@example.com; run add work
  mkdir -p "$CSWAP_DESKTOP_DIR"
  echo '{"lastKnownAccountUuid":"u9"}' > "$CSWAP_DESKTOP_DIR/config.json"
  run status
  assert_exit_code "$RC" 0 || return 1
  assert_eq "$OUT" "work (one@example.com)" "stdout stays data" || return 1
  assert_contains "$ERR" "the desktop login is a different account" || return 1
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
