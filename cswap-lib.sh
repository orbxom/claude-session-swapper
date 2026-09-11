#!/usr/bin/env bash
# cswap-lib.sh — shared helpers for cswap.sh and cswap-limits.sh.
# Not directly executable; meant to be sourced.
#
# Provides:
#   - bash 4 version check (runs at source time)
#   - hint_for / need              : dependency check + install-hint helpers
#   - cswap_home / profiles_dir    : where saved profiles live
#   - claude_dir / creds_file / claude_json_file : the live Claude Code files
#   - creds_read / creds_write     : the OAuth blob, from the Keychain or the file
#   - json_write_atomic <path>     : stdin -> temp file (0600) -> mv over path
#   - slot registry (SLOTS) + the `login` and `desktop` slots
#   - profile_* helpers, active_profile, capture_all / restore_all
#   - run_fzf                      : wraps the shared fzf flag set
#
# Slot contract. A slot is one swappable unit of Claude Code state. Each slot
# <s> listed in SLOTS defines four functions:
#   slot_<s>_capture     <profile_dir>  live state -> <profile_dir>/<s>.json
#   slot_<s>_restore     <profile_dir>  <profile_dir>/<s>.json -> live state
#   slot_<s>_identity                   fingerprint of live state ("" if none)
#   slot_<s>_identity_of <profile_dir>  same fingerprint read from the saved file
# A slot may also define a fifth, optional function:
#   slot_<s>_preflight                  refuse the whole operation before it
#                                       starts ("" = nothing to check)
# `preflight_all` runs every one of them before any slot writes anything, so a
# slot that cannot safely be swapped right now aborts the command instead of
# leaving half the state switched.
#
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

# base64: BSD spells decode -D and GNU -d (newer macOS takes both). Probe, and
# never emit line breaks, so the result survives a round trip through JSON.
b64_encode() { base64 | tr -d '\n'; }
b64_decode() {
  if [ -z "${_B64_DECODE:-}" ]; then
    if printf 'aGk=' | base64 -d >/dev/null 2>&1; then _B64_DECODE="-d"; else _B64_DECODE="-D"; fi
  fi
  base64 "$_B64_DECODE"
}

# --- credential store ---------------------------------------------------------
# Claude Code keeps the OAuth blob in one of two places, and which one is live
# is a property of the machine rather than of the platform: macOS normally uses
# the login Keychain and falls back to the file when the Keychain is
# unavailable; Linux uses the file. Both hold the same JSON object, of which we
# own .claudeAiOauth only — it also carries mcpOAuth and trustedDeviceToken.
#
# Service name, account name and the hex write below all mirror what Claude Code
# 2.1.268 itself does (`security find-generic-password -a <user> -w -s <service>`
# / `security add-generic-password -U -a <user> -s <service> -X <hex>`), so an
# item we write is indistinguishable from one it wrote.

CSWAP_SECURITY_BIN="${CSWAP_SECURITY:-security}"

sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256
  else sha256sum; fi | cut -d' ' -f1
}

# keychain_service: "Claude Code-credentials", suffixed with the first 8 hex of
# sha256(config dir) whenever the config dir has been moved, so a relocated
# install gets its own item. Claude Code derives it the same way, from
# CLAUDE_SECURESTORAGE_CONFIG_DIR if that is set at all (even to empty), else
# from CLAUDE_CONFIG_DIR.
keychain_service() {
  local base="Claude Code-credentials" dir
  if [ -n "${CLAUDE_SECURESTORAGE_CONFIG_DIR+set}" ]; then
    dir="$CLAUDE_SECURESTORAGE_CONFIG_DIR"
    [ -n "$dir" ] || { echo "$base"; return 0; }
  elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    dir="$CLAUDE_CONFIG_DIR"
  else
    echo "$base"; return 0
  fi
  echo "$base-$(printf '%s' "$dir" | sha256_hex | cut -c1-8)"
}

# keychain_account: $USER, or "claude-code-user" when it is unset or has a
# character Claude Code's own check rejects.
keychain_account() {
  local u="${USER:-}"
  [ -n "$u" ] || u="$(id -un 2>/dev/null || true)"
  [[ "$u" =~ ^[A-Za-z0-9._-]+$ ]] || u="claude-code-user"
  echo "$u"
}

keychain_read() {
  "$CSWAP_SECURITY_BIN" find-generic-password \
    -a "$(keychain_account)" -s "$(keychain_service)" -w 2>/dev/null
}

# keychain_write <json>: -U updates in place, so the item keeps its ACL and we
# never delete (and so never orphan) the MCP and trusted-device tokens beside
# the login. The payload goes as hex in argv because `security` offers nothing
# better: its stdin password prompt truncates at 128 bytes, and `security -i`
# chops a line this long into garbage. Claude Code passes it in argv for the
# same reason. On macOS another user cannot read this process's arguments.
keychain_write() {
  local hex
  hex="$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')"
  "$CSWAP_SECURITY_BIN" add-generic-password -U \
    -a "$(keychain_account)" -s "$(keychain_service)" -X "$hex" >/dev/null 2>&1
}

# creds_store: "keychain" or "file", decided once per run. A live Keychain item
# wins over the file, because that is the one Claude Code will read.
_CREDS_STORE=""
creds_store() {
  if [ -n "${CSWAP_CREDS_STORE:-}" ]; then echo "$CSWAP_CREDS_STORE"; return 0; fi
  if [ -z "$_CREDS_STORE" ]; then
    if command -v "$CSWAP_SECURITY_BIN" >/dev/null 2>&1 && [ -n "$(keychain_read)" ]; then
      _CREDS_STORE=keychain
    elif [ -s "$(creds_file)" ]; then
      _CREDS_STORE=file
    elif command -v "$CSWAP_SECURITY_BIN" >/dev/null 2>&1; then
      _CREDS_STORE=keychain   # logged out on a Mac: restore into the Keychain
    else
      _CREDS_STORE=file
    fi
  fi
  echo "$_CREDS_STORE"
}

# creds_read / creds_write: the credential blob, wherever it lives. Same
# contract as json_read / json_write_atomic, which is what the file store is.
creds_read() {
  local blob
  if [ "$(creds_store)" = keychain ]; then
    # No item, or an unreadable one, reads as {} — same contract as json_read.
    blob="$(keychain_read | jq . 2>/dev/null)" || blob=""
    if [ -n "$blob" ]; then echo "$blob"; else echo '{}'; fi
  else
    json_read "$(creds_file)"
  fi
}

creds_write() {
  local blob; blob="$(cat)"
  if [ "$(creds_store)" = keychain ]; then
    keychain_write "$(printf '%s' "$blob" | jq -c .)" || {
      echo "could not write the login keychain item ($(keychain_service))" >&2
      return 1
    }
  else
    printf '%s\n' "$blob" | json_write_atomic "$(creds_file)"
  fi
}

# creds_location: one line for humans, so `status` can say where the login is.
creds_location() {
  if [ "$(creds_store)" = keychain ]; then echo "keychain: $(keychain_service)"
  else echo "$(creds_file)"; fi
}

# --- slot: login -------------------------------------------------------------
# What it swaps: .claudeAiOauth from .credentials.json, plus .oauthAccount and
# .userID from .claude.json. Every other key in both files is left alone —
# .credentials.json also holds MCP OAuth tokens and .claude.json holds ~90 keys
# of UI state that should stay shared across accounts.

SLOTS=(login desktop)

slot_login_identity() {
  json_read "$(claude_json_file)" | jq -r '.oauthAccount.accountUuid // empty'
}

slot_login_identity_of() {
  json_read "$1/login.json" | jq -r '.account.accountUuid // empty'
}

slot_login_capture() {
  local dir="$1" creds acct
  creds="$(creds_read | jq '.claudeAiOauth // empty')"
  acct="$(json_read "$(claude_json_file)" | jq '.oauthAccount // empty')"
  if [ -z "$creds" ] || [ -z "$acct" ]; then
    echo "not logged in to claude (no login in $(creds_location))" >&2
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
  creds_read \
    | jq --argjson s "$saved" '.claudeAiOauth = $s.credentials' \
    | creds_write
  json_read "$(claude_json_file)" \
    | jq --argjson s "$saved" '.oauthAccount = $s.account | .userID = $s.userID' \
    | json_write_atomic "$(claude_json_file)"
}

# --- slot: desktop -----------------------------------------------------------
# What it swaps: the Claude desktop app's signed-in account. That app is an
# Electron shell around claude.ai, so its login is a web session, not the OAuth
# blob the CLI uses:
#   Cookies                    the sessionKey cookie for .claude.ai (SQLite)
#   config.json                lastKnownAccountUuid, oauth:tokenCache[V2]
#   ant-device-registry.json   this account's device registration
# The two oauth:tokenCache values are "v10:" Electron safeStorage blobs,
# encrypted under the app-wide "Claude Safe Storage" keychain key rather than a
# per-account one, so they move verbatim: cswap never decrypts them and never
# asks the keychain for that key. Everything else in the app's support
# directory — caches, window state, MCP config, conversation storage — is left
# alone, the same way the login slot leaves the other 90 keys of .claude.json.
#
# The slot is a no-op when the app is not installed, when it has never been
# signed in, or when CSWAP_NO_DESKTOP is set (switch the CLI only).

desktop_dir()      { echo "${CSWAP_DESKTOP_DIR:-$HOME/Library/Application Support/Claude}"; }
desktop_config()   { echo "$(desktop_dir)/config.json"; }
desktop_cookies()  { echo "$(desktop_dir)/Cookies"; }
desktop_registry() { echo "$(desktop_dir)/ant-device-registry.json"; }

desktop_enabled() { [ -z "${CSWAP_NO_DESKTOP:-}" ] && [ -d "$(desktop_dir)" ]; }

# desktop_running: Electron keeps cookies in memory and rewrites them on quit,
# so anything we write under a live app is overwritten without warning.
desktop_running() {
  if [ -n "${CSWAP_DESKTOP_RUNNING:-}" ]; then [ "$CSWAP_DESKTOP_RUNNING" = 1 ]; return; fi
  pgrep -f 'Claude\.app/Contents/MacOS/Claude' >/dev/null 2>&1
}

slot_desktop_preflight() {
  desktop_enabled || return 0
  desktop_running || return 0
  echo "the Claude desktop app is running; quit it first (it rewrites its login on exit)" >&2
  echo "  or set CSWAP_NO_DESKTOP=1 to switch only the Claude Code login" >&2
  return 1
}

slot_desktop_identity() {
  desktop_enabled || return 0
  json_read "$(desktop_config)" | jq -r '.lastKnownAccountUuid // empty'
}

slot_desktop_identity_of() {
  json_read "$1/desktop.json" | jq -r '.accountUuid // empty'
}

slot_desktop_capture() {
  local dir="$1" cfg uuid cookies=""
  desktop_enabled || return 0
  cfg="$(json_read "$(desktop_config)")"
  uuid="$(echo "$cfg" | jq -r '.lastKnownAccountUuid // empty')"
  # Installed but never signed in: nothing to save, and not an error — the CLI
  # login is what the user asked to save.
  [ -n "$uuid" ] || return 0
  [ -f "$(desktop_cookies)" ] && cookies="$(b64_encode < "$(desktop_cookies)")"
  ensure_profiles_dir
  mkdir -p "$dir" && chmod 700 "$dir"
  jq -n --arg u "$uuid" \
        --argjson c "$(echo "$cfg" | jq '{"oauth:tokenCache", "oauth:tokenCacheV2"}')" \
        --argjson r "$(json_read "$(desktop_registry)")" \
        --arg ck "$cookies" --arg t "$(now_iso)" \
        '{accountUuid: $u, config: $c, registry: $r, cookies: $ck, savedAt: $t}' \
    | json_write_atomic "$dir/desktop.json"
}

slot_desktop_restore() {
  local dir="$1" saved
  desktop_enabled || return 0
  # A profile saved before the desktop app existed (or on a machine without it)
  # simply has no desktop half; switching the CLI login is still correct.
  [ -f "$dir/desktop.json" ] || return 0
  saved="$(json_read "$dir/desktop.json")"
  [ "$(echo "$saved" | jq -r '.accountUuid // empty')" ] || {
    echo "profile has no saved desktop login: $dir/desktop.json" >&2
    return 1
  }
  json_read "$(desktop_config)" \
    | jq --argjson s "$saved" '. + $s.config | .lastKnownAccountUuid = $s.accountUuid' \
    | json_write_atomic "$(desktop_config)"
  # Merge, not replace: the registry can hold an entry per account and the
  # others are still valid.
  json_read "$(desktop_registry)" \
    | jq --argjson s "$saved" '. + $s.registry' \
    | json_write_atomic "$(desktop_registry)"
  if [ -n "$(echo "$saved" | jq -r '.cookies // empty')" ]; then
    local tmp; tmp="$(mktemp "$(desktop_dir)/.cswap.XXXXXX")"
    echo "$saved" | jq -r '.cookies' | b64_decode > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$(desktop_cookies)"
    # A leftover journal or WAL would replay rows from the login we just
    # replaced. The app rebuilds both on next launch.
    rm -f "$(desktop_cookies)-journal" "$(desktop_cookies)-wal" "$(desktop_cookies)-shm"
  fi
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

# preflight_all: give every slot that defines a preflight the chance to refuse
# before anything is written. Called by cswap.sh ahead of any command that
# changes live state.
# slots_out_of_sync: names of the slots whose live identity disagrees with the
# first slot's — the desktop app signed in as someone else, say. For humans;
# cswap.sh prints the names without knowing what they mean.
slots_out_of_sync() {
  local s first other
  first="$("slot_${SLOTS[0]}_identity")" || return 0
  [ -n "$first" ] || return 0
  for s in "${SLOTS[@]:1}"; do
    other="$("slot_${s}_identity")" || other=""
    if [ -n "$other" ] && [ "$other" != "$first" ]; then echo "$s"; fi
  done
  return 0
}

preflight_all() {
  local s rc=0
  for s in "${SLOTS[@]}"; do
    declare -F "slot_${s}_preflight" >/dev/null || continue
    "slot_${s}_preflight" || rc=1
  done
  return "$rc"
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
