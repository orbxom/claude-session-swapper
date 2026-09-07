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
   │  add/new/list/      │  SLOTS=(login)           │
   │  status/rm/switch   │  slot_login_{capture,    │
   │  picker             │    restore,identity,     │
   │                     │    identity_of}          │
   └── -l/--limits ──exec───────────────────────────┘
```

Live files (Claude Code's, never created by us except on restore):

- `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json` → we own `.claudeAiOauth` only.
- `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`) → we own `.oauthAccount` and `.userID` only.

Saved state: `${CSWAP_HOME:-~/.config/cswap}/profiles/<name>/login.json`
(`{credentials, account, userID, savedAt}`), 0600 in 0700 dirs.

The *active* profile is derived on every call by matching the live
`accountUuid` against each saved profile. Nothing stores "current".

## Invariants

### Enforced by cswap-lib.sh

1. **Restore touches only the login keys.** Every other key in both live files
   survives byte-for-byte in meaning (`test_restore_replaces_login_and_preserves_other_keys`).
   `.credentials.json` also carries MCP OAuth tokens; `.claude.json` carries
   ~90 keys of UI state. Never `>` a live file; always `jq … | json_write_atomic`.
2. **Every write is atomic and 0600.** `json_write_atomic` writes a same-dir
   temp file, chmods, then `mv`s (`test_json_write_atomic_sets_mode_600`).
3. **Capture refuses when logged out** rather than writing an empty profile
   (`test_capture_fails_when_logged_out`).
4. **Slots are the only extension point.** `cswap.sh` calls `capture_all` /
   `restore_all` / `active_profile`; it never names `login`. A new slot adds
   four `slot_<name>_*` functions and appends to `SLOTS`.
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
  `CSWAP_NOW`) and a stub `claude` on PATH. Fixture helpers must run in the
  caller's shell, not `$(…)`, or their exports are lost — the first test run
  of this repo wrote real tokens into `~/.config/cswap/profiles/alpha` for
  exactly that reason.
- Keep README "How it works" and this file's invariants in sync with the code.
- Commit subjects: `cswap: …`, `limits: …`, `docs: …`, `tests: …`; body says
  why, ends with a `Tests: N shell` line.
- The endpoints in `cswap-limits.sh` (`USAGE_URL`, `TOKEN_URL`, `CLIENT_ID`)
  were read from the Claude Code 2.1.263 binary. If `--limits` starts failing
  after a Claude Code update, re-check them first:
  `grep -a -o 'https://[a-z.]*/v1/oauth/token' "$(readlink -f ~/.local/bin/claude)"`.
