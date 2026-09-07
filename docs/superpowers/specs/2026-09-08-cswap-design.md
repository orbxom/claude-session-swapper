# cswap — design (2026-09-08)

## Problem

One machine, two Claude accounts (personal, and a Claude Team seat at work).
Claude Code has no profile switching; the login lives in two files under the
home directory. Re-running `claude auth login` each time costs a browser
round-trip and loses the other account's session.

## Decisions

- **In-place stash and restore of the login only.** `~/.claude` stays shared
  (settings, plugins, history, MCP OAuth tokens). Chosen over a
  `CLAUDE_CONFIG_DIR`-per-profile layout, which would split plugins and history
  and is the deferred "settings swapper" feature. Chosen over symlinking the
  credentials file, because the account identity is embedded in the large
  shared `~/.claude.json` and cannot be symlinked per profile.
- **Slot abstraction.** A slot is one swappable unit with four functions
  (capture, restore, identity, identity_of) registered in a `SLOTS` array.
  Only `login` ships. A future `settings` or `plugins` slot adds four functions
  and one array entry.
- **Active profile is derived**, by matching the live `accountUuid` against
  saved profiles. No pointer file.
- **Capture before restore, always.** Claude Code rotates the refresh token
  while running. A stale saved copy would fail on the next switch.
- **Unsaved live login blocks a switch** unless `--discard`.
- **Running `claude` processes are not checked** (user decision).
- **`--limits` refreshes stashed tokens but never the live one.** A running
  `claude` owns the live token; refreshing it from outside risks invalidating
  the process's in-memory refresh token.
- **Command name `cswap`**, plain executable symlinked into `~/.local/bin`.
  No sourced shell function: nothing needs to `cd` or export env.
- Conventions copied from `~/repos/wt`: bash + jq + fzf, hand-rolled arg
  parsing and test harness, stdout-is-data/stderr-is-human, no ANSI colour,
  lowercase one-line errors with a remedy in parentheses, exit 0/1/2/130.

## Facts about Claude Code 2.1.263 (native install, Linux)

| File | Keys cswap owns | Left alone |
|---|---|---|
| `~/.claude/.credentials.json` | `.claudeAiOauth` `{accessToken, refreshToken, expiresAt(ms), refreshTokenExpiresAt(ms), scopes, subscriptionType, rateLimitTier}` | `.mcpOAuth.*` |
| `~/.claude.json` | `.oauthAccount`, `.userID` | ~90 other keys |

With `CLAUDE_CONFIG_DIR` set, both files live under it. Access tokens last
about 8 h, refresh tokens about 30 days.

Usage endpoint (what `/usage` calls): `GET https://api.anthropic.com/api/oauth/usage`
with `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`.
Returns `limits[] {kind: session|weekly_all|weekly_scoped, percent, severity,
resets_at, scope.model.display_name}` and `extra_usage {is_enabled,
monthly_limit, used_credits, decimal_places}`. 401 on a bad token.

Token endpoint (from the binary's `TOKEN_URL`): `POST https://platform.claude.com/v1/oauth/token`,
client id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`, body
`{grant_type: refresh_token, refresh_token, client_id}`. The response parser
accepts `access_token`, optional `refresh_token`, optional `expires_in`
(default 3600 s). The real response shape was not exercised during
development; the first real refresh happens the first time `--limits` meets an
expired stashed profile.

## Storage

```
${CSWAP_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/cswap}/   0700
  profiles/<name>/                                        0700
    login.json                                            0600
      {credentials: <claudeAiOauth>, account: <oauthAccount>, userID, savedAt}
```

Names match `^[A-Za-z0-9_-]+$`.

## Commands

| Command | Behaviour | Exit |
|---|---|---|
| `cswap` | fzf picker, ● = active, switch to pick | 0 / 130 / 1 |
| `cswap <name> [--discard]` | capture current → restore target | 0 / 1 |
| `cswap add <name> [--force]` | capture live login as `<name>` | 0 / 1 / 2 |
| `cswap new <name>` | capture current, `claude auth logout`, `claude auth login`, capture as `<name>` | 0 / 1 |
| `cswap list` / `ls` | table on stdout | 0 |
| `cswap status` | `work (email)` / `unsaved login: email` / `not logged in` | 0 / 1 |
| `cswap rm <name> [--yes]` | confirm, delete profile dir only | 0 / 130 / 1 |
| `cswap -l` / `--limits [name…] [--no-refresh]` | per-profile usage blocks | 0 if any rendered |

## Out of scope

- Settings / plugins slots (next feature; the slot contract is ready).
- Detecting running `claude` processes.
- Switching `gh` or git identity.
