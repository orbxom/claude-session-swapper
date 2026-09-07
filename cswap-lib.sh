#!/usr/bin/env bash
# cswap-lib.sh — shared helpers for cswap.sh and cswap-limits.sh.
# Not directly executable; meant to be sourced.
#
# Provides:
#   - bash 4 version check (runs at source time)
#   - hint_for / need              : dependency check + install-hint helpers
#   - cswap_home / profiles_dir    : where saved profiles live
#   - claude_dir / creds_file / claude_json_file : the live Claude Code files
#   - json_write_atomic <path>     : stdin -> temp file (0600) -> mv over path
#   - slot registry (SLOTS) + the `login` slot
#   - profile_* helpers, active_profile, capture_all / restore_all
#   - run_fzf                      : wraps the shared fzf flag set
#
# Slot contract. A slot is one swappable unit of Claude Code state. Each slot
# <s> listed in SLOTS defines four functions:
#   slot_<s>_capture     <profile_dir>  live state -> <profile_dir>/<s>.json
#   slot_<s>_restore     <profile_dir>  <profile_dir>/<s>.json -> live state
#   slot_<s>_identity                   fingerprint of live state ("" if none)
#   slot_<s>_identity_of <profile_dir>  same fingerprint read from the saved file
# The first slot in SLOTS decides which profile counts as "active". Adding a
# settings or plugins slot later means writing those four functions and
# appending the name to SLOTS; cswap.sh never names a slot directly.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "cswap requires bash 4 or newer." >&2
  echo "  current: ${BASH_VERSION:-unknown}" >&2
  echo "  macOS:   brew install bash   then re-run with the homebrew bash" >&2
  exit 1
fi

# --- dependencies ------------------------------------------------------------

hint_for() {
  local tool="$1"
  if command -v brew >/dev/null 2>&1; then
    echo "brew install $tool"
  elif command -v apt >/dev/null 2>&1; then
    echo "sudo apt install $tool"
  elif command -v dnf >/dev/null 2>&1; then
    echo "sudo dnf install $tool"
  elif command -v pacman >/dev/null 2>&1; then
    echo "sudo pacman -S $tool"
  else
    echo "(install $tool with your package manager)"
  fi
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 not found. install with: $(hint_for "$1")" >&2
    exit 1
  }
}

# --- paths -------------------------------------------------------------------

cswap_home()   { echo "${CSWAP_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/cswap}"; }
profiles_dir() { echo "$(cswap_home)/profiles"; }

# Claude Code keeps .credentials.json inside its config dir, but .claude.json
# sits in $HOME unless CLAUDE_CONFIG_DIR is set, in which case both move into
# that dir. Mirror that so a test (or a relocated install) only needs one env.
claude_dir()  { echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
creds_file()  { echo "$(claude_dir)/.credentials.json"; }
claude_json_file() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    echo "$CLAUDE_CONFIG_DIR/.claude.json"
  else
    echo "$HOME/.claude.json"
  fi
}

# --- json --------------------------------------------------------------------

# json_write_atomic <path>: stdin -> temp in the same dir -> chmod 600 -> mv.
# Same-dir temp keeps the mv a rename, so a reader never sees a half-written
# file. 0600 because every file this tool writes holds OAuth tokens.
json_write_atomic() {
  local f="$1" tmp
  mkdir -p "$(dirname "$f")"
  tmp="$(mktemp "$(dirname "$f")/.cswap.XXXXXX")"
  cat > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$f"
}

# json_read <path>: prints the file's JSON, or {} when missing/invalid, so
# callers can always pipe into jq without an existence check.
json_read() { jq . "$1" 2>/dev/null || echo '{}'; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- slot: login -------------------------------------------------------------
# What it swaps: .claudeAiOauth from .credentials.json, plus .oauthAccount and
# .userID from .claude.json. Every other key in both files is left alone —
# .credentials.json also holds MCP OAuth tokens and .claude.json holds ~90 keys
# of UI state that should stay shared across accounts.

SLOTS=(login)

slot_login_identity() {
  json_read "$(claude_json_file)" | jq -r '.oauthAccount.accountUuid // empty'
}

slot_login_identity_of() {
  json_read "$1/login.json" | jq -r '.account.accountUuid // empty'
}

slot_login_capture() {
  local dir="$1" creds acct
  creds="$(json_read "$(creds_file)" | jq '.claudeAiOauth // empty')"
  acct="$(json_read "$(claude_json_file)" | jq '.oauthAccount // empty')"
  if [ -z "$creds" ] || [ -z "$acct" ]; then
    echo "not logged in to claude (nothing to save)" >&2
    return 1
  fi
  ensure_profiles_dir
  mkdir -p "$dir" && chmod 700 "$dir"
  json_read "$(claude_json_file)" \
    | jq --argjson c "$creds" --argjson a "$acct" --arg t "$(now_iso)" \
         '{credentials: $c, account: $a, userID: (.userID // null), savedAt: $t}' \
    | json_write_atomic "$dir/login.json"
}

slot_login_restore() {
  local dir="$1" saved
  saved="$(json_read "$dir/login.json")"
  [ "$(echo "$saved" | jq -r '.credentials.accessToken // empty')" ] || {
    echo "profile has no saved login: $dir/login.json" >&2
    return 1
  }
  json_read "$(creds_file)" \
    | jq --argjson s "$saved" '.claudeAiOauth = $s.credentials' \
    | json_write_atomic "$(creds_file)"
  json_read "$(claude_json_file)" \
    | jq --argjson s "$saved" '.oauthAccount = $s.account | .userID = $s.userID' \
    | json_write_atomic "$(claude_json_file)"
}

# --- profiles ----------------------------------------------------------------

# ensure_profiles_dir: create ~/.config/cswap/profiles with 0700 on every level
# we own (mkdir -p -m only applies the mode to the leaf).
ensure_profiles_dir() {
  mkdir -p "$(profiles_dir)"
  chmod 700 "$(cswap_home)" "$(profiles_dir)"
}

valid_profile_name() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

profile_dir()    { echo "$(profiles_dir)/$1"; }
profile_exists() { [ -d "$(profile_dir "$1")" ]; }

profile_list() {
  local d
  [ -d "$(profiles_dir)" ] || return 0
  for d in "$(profiles_dir)"/*/; do
    [ -d "$d" ] && basename "$d"
  done | sort
}

profile_email() { json_read "$(profile_dir "$1")/login.json" | jq -r '.account.emailAddress // "?"'; }
profile_org()   { json_read "$(profile_dir "$1")/login.json" | jq -r '.account.organizationName // "?"'; }

live_email() { json_read "$(claude_json_file)" | jq -r '.oauthAccount.emailAddress // empty'; }

# active_profile: the saved profile whose identity matches the live login.
# Derived every call, never stored, so it can't go stale when the user logs in
# or out behind our back. Prints nothing when unsaved or logged out.
active_profile() {
  local live name id_fn="slot_${SLOTS[0]}_identity" of_fn="slot_${SLOTS[0]}_identity_of"
  live="$("$id_fn")"
  [ -n "$live" ] || return 0
  while read -r name; do
    [ -n "$name" ] || continue
    if [ "$("$of_fn" "$(profile_dir "$name")")" = "$live" ]; then
      echo "$name"
      return 0
    fi
  done < <(profile_list)
}

capture_all() {
  local name="$1" s
  for s in "${SLOTS[@]}"; do "slot_${s}_capture" "$(profile_dir "$name")" || return 1; done
}

restore_all() {
  local name="$1" s
  for s in "${SLOTS[@]}"; do "slot_${s}_restore" "$(profile_dir "$name")" || return 1; done
}

# --- fzf ---------------------------------------------------------------------

# Rows are "<display>\t<hidden name>"; only column 1 is shown and searched.
run_fzf() {
  local prompt="$1" header="$2"
  fzf \
    --delimiter=$'\t' \
    --with-nth=1 \
    --nth=1 \
    --layout=reverse \
    --height=40% \
    --prompt="$prompt" \
    --header="$header"
}
