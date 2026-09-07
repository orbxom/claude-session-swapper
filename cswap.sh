#!/usr/bin/env bash
# cswap.sh — swap the Claude Code login between saved profiles.
#
# Usage: cswap                      fzf picker over saved profiles
#        cswap <name> [--discard]   switch to <name>
#        cswap add <name> [--force] save the current login as <name>
#        cswap new <name>           log out, log in, save the result as <name>
#        cswap list|ls              list saved profiles (● = active)
#        cswap status               which profile the live login matches
#        cswap rm <name> [--yes]    delete a saved profile
#        cswap -l|--limits [name…]  usage limits for every profile
set -euo pipefail

# readlink -f: the installed command is a symlink in ~/.local/bin, and the lib
# lives next to the real file, not next to the link.
_CSWAP_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
_CSWAP_LIB="$_CSWAP_DIR/cswap-lib.sh"
[ -r "$_CSWAP_LIB" ] || { echo "cswap-lib.sh missing next to $(basename "$0")" >&2; exit 1; }
source "$_CSWAP_LIB"
unset _CSWAP_LIB
CSWAP_LIMITS="$_CSWAP_DIR/cswap-limits.sh"

usage() {
  cat <<EOF
Usage: cswap [<name>] [--discard]
       cswap add <name> [--force]
       cswap new <name>
       cswap list | ls
       cswap status
       cswap rm <name> [--yes]
       cswap -l | --limits [name…] [--no-refresh]

Swaps the Claude Code login (OAuth tokens + account identity) between saved
profiles. Everything else under ~/.claude — settings, plugins, history, MCP
tokens — stays shared. With no arguments, opens an fzf picker.

Before restoring another profile, the live login is always saved back into the
profile it belongs to, because Claude Code rotates the refresh token while it
runs. A live login that matches no saved profile blocks the switch unless you
pass --discard or save it first with 'cswap add'.

Commands:
  <name>          Switch to profile <name>.
  add <name>      Save the current live login as <name>. Refuses to overwrite
                  an existing profile unless --force.
  new <name>      Save the current login, run 'claude auth logout' then
                  'claude auth login' (opens a browser), and save the new
                  login as <name>.
  list, ls        Print saved profiles; ● marks the one the live login matches.
  status          Print the active profile, 'unsaved login: <email>', or
                  'not logged in' (exit 1).
  rm <name>       Delete a saved profile after confirming. Never touches the
                  live login.
  -l, --limits    Show 5h/7d usage windows for each profile (see cswap-limits.sh).
  -h, --help      Show this help and exit.

Environment:
  CSWAP_HOME         Where profiles live (default ~/.config/cswap).
  CLAUDE_CONFIG_DIR  Claude Code config dir (default ~/.claude).

Exits 0 on success, 130 on cancel (fzf Esc / declined confirm), 1 on error,
2 on bad arguments.
EOF
}

check_name() {
  valid_profile_name "${1:-}" || { echo "invalid profile name: '${1:-}' (letters, digits, - and _ only)" >&2; exit 2; }
}

# --- commands ----------------------------------------------------------------

cmd_switch() {
  local name="$1" discard="$2" cur live_id
  profile_exists "$name" || { echo "no such profile: $name (see: cswap list)" >&2; exit 1; }
  cur="$(active_profile)"
  live_id="$(slot_login_identity)"
  if [ -n "$cur" ]; then
    # Save the live login back first: its refresh token may have rotated since
    # the profile was last written, and the old copy would fail on next use.
    capture_all "$cur"
  elif [ -n "$live_id" ] && [ "$discard" -ne 1 ]; then
    echo "current login ($(live_email)) is not saved (cswap add <name>, or cswap $name --discard)" >&2
    exit 1
  fi
  restore_all "$name"
  if [ "$cur" = "$name" ]; then
    echo "already on $name ($(profile_email "$name"))" >&2
  else
    echo "switched to $name ($(profile_email "$name"))" >&2
  fi
}

cmd_add() {
  local name="$1" force="$2"
  [ -n "$(slot_login_identity)" ] || { echo "not logged in to claude (run: claude auth login)" >&2; exit 1; }
  if profile_exists "$name" && [ "$force" -ne 1 ]; then
    echo "profile already exists: $name (use --force to overwrite)" >&2
    exit 1
  fi
  capture_all "$name"
  echo "saved $name ($(profile_email "$name"))" >&2
}

cmd_new() {
  local name="$1" cur live_id
  profile_exists "$name" && { echo "profile already exists: $name" >&2; exit 1; }
  need claude
  cur="$(active_profile)"
  live_id="$(slot_login_identity)"
  if [ -n "$cur" ]; then
    capture_all "$cur"
    echo "saved $cur ($(profile_email "$cur"))" >&2
  elif [ -n "$live_id" ]; then
    echo "current login ($(live_email)) is not saved (cswap add <name> first)" >&2
    exit 1
  fi
  if [ -n "$live_id" ]; then
    claude auth logout >&2 || { echo "claude auth logout failed" >&2; exit 1; }
  fi
  claude auth login >&2 || {
    echo "claude auth login failed; you are now logged out (cswap <name> to restore a saved profile)" >&2
    exit 1
  }
  [ -n "$(slot_login_identity)" ] || {
    echo "login did not complete; you are now logged out (cswap <name> to restore a saved profile)" >&2
    exit 1
  }
  capture_all "$name"
  echo "saved $name ($(profile_email "$name"))" >&2
}

cmd_list() {
  local cur name mark
  cur="$(active_profile)"
  while read -r name; do
    [ -n "$name" ] || continue
    mark=" "; [ "$name" = "$cur" ] && mark="●"
    printf '%s %-20s %-36s %s\n' "$mark" "$name" "$(profile_email "$name")" "$(profile_org "$name")"
  done < <(profile_list)
  if [ -z "$cur" ] && [ -n "$(slot_login_identity)" ]; then
    echo "live login $(live_email) is not saved (cswap add <name>)" >&2
  fi
}

cmd_status() {
  local cur
  cur="$(active_profile)"
  if [ -n "$cur" ]; then
    echo "$cur ($(profile_email "$cur"))"
  elif [ -n "$(slot_login_identity)" ]; then
    echo "unsaved login: $(live_email)"
  else
    echo "not logged in"
    exit 1
  fi
}

cmd_rm() {
  local name="$1" yes="$2" answer
  profile_exists "$name" || { echo "no such profile: $name" >&2; exit 1; }
  if [ "$yes" -ne 1 ]; then
    printf 'Delete profile %s (%s)? [y/N] ' "$name" "$(profile_email "$name")" >&2
    read -r answer || exit 130
    case "$answer" in y|Y|yes|YES) ;; *) echo "cancelled" >&2; exit 130 ;; esac
  fi
  rm -rf "$(profile_dir "$name")"
  echo "deleted $name" >&2
}

cmd_pick() {
  need fzf
  local cur rows picked name
  cur="$(active_profile)"
  rows="$(while read -r name; do
    [ -n "$name" ] || continue
    if [ "$name" = "$cur" ]; then mark="●"; else mark=" "; fi
    printf '%s %-20s %s\t%s\n' "$mark" "$name" "$(profile_email "$name")" "$name"
  done < <(profile_list))"
  [ -n "$rows" ] || { echo "no saved profiles (save the current login with: cswap add <name>)" >&2; exit 1; }
  picked="$(echo "$rows" | run_fzf 'profile › ' "  $(printf '%-20s' NAME) EMAIL")" || exit $?
  name="${picked##*$'\t'}"
  cmd_switch "$name" 0
}

# --- dispatch ----------------------------------------------------------------

DISCARD=0
FORCE=0
YES=0
CMD=""
NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)      usage; exit 0 ;;
    -l|--limits)    shift; exec "$CSWAP_LIMITS" "$@" ;;
    --discard)      DISCARD=1; shift ;;
    --force)        FORCE=1; shift ;;
    --yes|-y)       YES=1; shift ;;
    -*)             echo "unknown flag: $1" >&2; exit 2 ;;
    add|new|list|ls|status|rm)
      [ -z "$CMD" ] || { echo "unexpected argument: $1" >&2; exit 2; }
      CMD="$1"; shift ;;
    *)
      [ -z "$NAME" ] || { echo "unexpected argument: $1" >&2; exit 2; }
      NAME="$1"; shift ;;
  esac
done

need jq

case "$CMD" in
  add)    check_name "$NAME"; cmd_add "$NAME" "$FORCE" ;;
  new)    check_name "$NAME"; cmd_new "$NAME" ;;
  list|ls) cmd_list ;;
  status) cmd_status ;;
  rm)     check_name "$NAME"; cmd_rm "$NAME" "$YES" ;;
  "")
    if [ -n "$NAME" ]; then check_name "$NAME"; cmd_switch "$NAME" "$DISCARD"
    else cmd_pick; fi ;;
esac
