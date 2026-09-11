# CLAUDE.md

## What this repo is

`cswap` swaps the Claude Code login between saved profiles (personal vs work on
one machine) and shows every profile's usage limits. Pure bash + jq; fzf for the
picker, curl for `--limits`. There is no build step, no linter, no package
manager. Install is a symlink from `~/.local/bin/cswap` to `cswap.sh`. Sibling
project with the same conventions: `~/repos/wt`.

## Commands

```bash
bash test/run.sh                 # all tests (must pass before committing)
bash cswap.test.sh               # one file
bash cswap-lib.test.sh
bash cswap-limits.test.sh
ln -sfn "$PWD/cswap.sh" ~/.local/bin/cswap   # install
cswap --help
```

To run a subset, pass a prefix: `bash cswap.test.sh switch` runs every
`test_switch*` function.

## Architecture

```
cswap.sh ──source──▶ cswap-lib.sh ◀──source── cswap-limits.sh
   │                     │                          ▲
   │  add/new/list/      │  SLOTS=(login desktop)   │
   │  status/rm/switch   │  slot_<s>_{capture,      │
   │  picker             │    restore,identity,     │
   │                     │    identity_of,          │
   │                     │    preflight?}           │
   └── -l/--limits ──exec───────────────────────────┘
```

Live state (Claude Code's, never created by us except on restore):

- The credential blob → we own `.claudeAiOauth` only. It lives in **one of two
  stores**, chosen at runtime by `creds_store()`: the macOS login Keychain
  (service `Claude Code-credentials`, account `$USER`) when an item is there,
  else `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`. Read and write it
  only through `creds_read` / `creds_write`; nothing outside cswap-lib.sh may
  name `creds_file`.
- `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`) → we own `.oauthAccount` and `.userID` only.

The Claude desktop app (`~/Library/Application Support/Claude`, an Electron
shell around claude.ai) has its own, unrelated login — a web session, not the
OAuth blob:

- `Cookies` (SQLite) → the `sessionKey` cookie for `.claude.ai`.
- `config.json` → we own `lastKnownAccountUuid`, `oauth:tokenCache`,
  `oauth:tokenCacheV2` only (~50 other keys of UI state stay).
- `ant-device-registry.json` → one entry per account UUID; we merge, never replace.

Saved state: `${CSWAP_HOME:-~/.config/cswap}/profiles/<name>/<slot>.json`, 0600
in 0700 dirs — `login.json` (`{credentials, account, userID, savedAt}`) and,
when the desktop app is installed, `desktop.json`
(`{accountUuid, config, registry, cookies, savedAt}`, cookies base64).

The *active* profile is derived on every call by matching the live
`accountUuid` against each saved profile. Nothing stores "current".

## Invariants

### Enforced by cswap-lib.sh

1. **Restore touches only the login keys.** Every other key in both live stores
   survives byte-for-byte in meaning (`test_restore_replaces_login_and_preserves_other_keys`,
   `test_capture_and_restore_through_the_keychain`). The credential blob also
   carries MCP OAuth tokens and `trustedDeviceToken`; `.claude.json` carries
   ~90 keys of UI state. Never `>` a live file; always `jq … | json_write_atomic`
   (file) or `jq … | creds_write` (either store).
2. **Every write is atomic and 0600.** `json_write_atomic` writes a same-dir
   temp file, chmods, then `mv`s (`test_json_write_atomic_sets_mode_600`).
3. **Capture refuses when logged out** rather than writing an empty profile
   (`test_capture_fails_when_logged_out`).
4. **Slots are the only extension point.** `cswap.sh` calls `capture_all` /
   `restore_all` / `preflight_all` / `active_profile` / `slots_out_of_sync`; it
   never names `login` or `desktop`. A new slot adds four `slot_<name>_*`
   functions (plus an optional `_preflight`) and appends to `SLOTS`. `SLOTS[0]`
   decides which profile is active, so the Claude Code login stays
   authoritative.
4b. **The Keychain item is updated, never replaced.** `keychain_write` uses
   `security add-generic-password -U` with the payload as `-X` hex, exactly as
   Claude Code 2.1.268 does, so the item keeps its ACL and cswap is
   indistinguishable from Claude Code as a writer. cswap never calls
   `delete-generic-password`: the item also holds MCP and trusted-device tokens.
   The hex goes in argv because `security` has no usable alternative — its stdin
   password prompt truncates at 128 bytes and `security -i` mangles a line this
   long — and macOS shows a process's arguments only to its own user.
5. **Profile names match `^[A-Za-z0-9_-]+$`** so a name can never escape
   `profiles/` (`test_valid_profile_name`, exit 2 at the CLI).

### Enforced by cswap.sh

6. **Capture before restore.** A switch first saves the live login into the
   profile it matches, because Claude Code rotates the refresh token while it
   runs (`test_switch_saves_rotated_token_before_restoring`).
7. **An unsaved live login blocks the switch** unless `--discard`
   (`test_switch_refuses_unsaved_login_without_discard`). Losing a login you
   can't get back without a browser round-trip is the one thing this tool must
   not do silently.
8. **`rm` deletes only the profile dir** and asks first; EOF on stdin is a
   "no" (`test_rm_requires_confirmation_and_never_touches_live`).
9. **stdout is data, stderr is for humans.** `list`/`status` print to stdout;
   everything else (`saved …`, `switched to …`, errors) goes to stderr. Exit
   codes: 0 ok, 1 error, 2 bad args, 130 cancelled.
10. **`new` never invokes `claude` if the current login is unsaved**
    (`test_new_refuses_unsaved_login`), and reports "you are now logged out" if
    login fails after logout (`test_new_reports_failed_login`).
11. **No ANSI colour.** Glyphs only (`●`, `·`, `›`), same as wt.

### Enforced by the desktop slot

4c. **A missing, never-signed-in or opted-out desktop app is a no-op, not an
   error** (`test_desktop_slot_is_inert_without_the_app`,
   `test_desktop_capture_skips_an_app_never_signed_in`), and a profile saved
   without a desktop half still switches the CLI login
   (`test_desktop_restore_skips_a_profile_saved_without_it`). `CSWAP_NO_DESKTOP`
   turns the slot off entirely.
4d. **Nothing is swapped while the app is running.** Electron holds cookies in
   memory and rewrites them on quit, so `slot_desktop_preflight` refuses and
   `preflight_all` aborts the command before any slot has written
   (`test_switch_refuses_while_the_desktop_app_runs`). That is what the
   preflight hook exists for: a half-switched session is worse than no switch.
4e. **The encrypted blobs are moved, never opened.** `oauth:tokenCache[V2]` and
   the cookie values are encrypted under the app-wide `Claude Safe Storage`
   key, not a per-account one, so they round-trip verbatim. cswap must never
   read that keychain key — doing so would put a GUI authorization prompt in
   the middle of a switch.
4f. **A stale `Cookies-journal`/`-wal` is removed on restore**, or SQLite
   replays rows from the login we just replaced
   (`test_desktop_restore_clears_a_stale_cookie_journal`).

### Enforced by cswap-limits.sh

12. **The live token is never refreshed by cswap** — a running `claude` owns it
    (`test_expired_active_token_is_not_refreshed`). Only stashed profiles are
    refreshed, and the new pair is written back atomically
    (`test_expired_stashed_token_is_refreshed_and_written_back`).
13. **One profile failing never aborts the batch**; exit 1 only if none
    rendered (`test_401_and_500_are_reported_per_profile_and_batch_continues`).
14. **All network goes through `${CSWAP_CURL:-curl}`** and time through
    `${CSWAP_NOW:-$(date +%s)}` so tests are offline and deterministic.
15. **Limit rows are split on `\x1f`, not tab.** Tab is IFS whitespace and
    `read` collapses the empty model column of unscoped limits.

## When making changes

- Tests use env seams (`CSWAP_HOME`, `CLAUDE_CONFIG_DIR`, `CSWAP_CURL`,
  `CSWAP_NOW`, `CSWAP_SECURITY`, `CSWAP_CREDS_STORE`, `CSWAP_DESKTOP_DIR`,
  `CSWAP_DESKTOP_RUNNING`) and a stub `claude` on PATH. Every sandbox points
  `CSWAP_DESKTOP_DIR` at a path that does not exist, so a test can never see
  the real desktop app — without that, the whole suite fails on a machine
  where it happens to be open. **No test may touch the real login Keychain**: every sandbox pins
  `CSWAP_CREDS_STORE=file`, and the keychain tests point `CSWAP_SECURITY` at a
  stub (`use_stub_keychain`). Fixture helpers must run in the
  caller's shell, not `$(…)`, or their exports are lost — the first test run
  of this repo wrote real tokens into `~/.config/cswap/profiles/alpha` for
  exactly that reason.
- **No GNU-only flags.** Linux and macOS are both first-class, so `date -d`,
  `stat -c`, `readlink -f` and `%P` are all out. Where the two userlands differ,
  probe the capability at runtime and cache the answer (`fmt_epoch` in
  cswap-limits.sh) — never branch on `uname`. Parsing that jq can do (ISO 8601
  timestamps: `iso_to_epoch`) belongs in jq, which behaves the same everywhere.
  Count characters yourself rather than with `${#s}`: under `LC_CTYPE=C` that
  counts bytes and the usage bars come out short. In tests, file modes go
  through the `file_mode` helper, and BSD `wc -l` pads its count, so pipe
  through `tr -d '[:space:]'` before comparing.
- Keep README "How it works" and this file's invariants in sync with the code.
- Commit subjects: `cswap: …`, `limits: …`, `docs: …`, `tests: …`; body says
  why, ends with a `Tests: N shell` line.
- The endpoints in `cswap-limits.sh` (`USAGE_URL`, `TOKEN_URL`, `CLIENT_ID`)
  were read from the Claude Code 2.1.263 binary. If `--limits` starts failing
  after a Claude Code update, re-check them first:
  `grep -a -o 'https://[a-z.]*/v1/oauth/token' "$(readlink -f ~/.local/bin/claude)"`.
