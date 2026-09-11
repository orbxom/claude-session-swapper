# cswap — Claude Code account swapper

Swaps the Claude Code login — and the Claude desktop app's — between saved
profiles so one machine can run
`claude` as a personal account or a work account. Everything else under
`~/.claude` — settings, plugins, history, MCP tokens — stays shared. Also shows
every profile's usage limits in one place without switching.

```
$ cswap list
● work                 zach@company.example                 Company Inc
  personal             zach@example.com                     Personal

$ cswap personal
switched to personal (zach@example.com)

$ cswap --limits
● personal   zach@example.com · Personal
    5h session      [████████▌ ]  85%  resets 1:10am
    7d all models   [████▌     ]  46%  resets Thu 6pm
    7d Fable        [███████▌  ]  78%  resets Thu 6pm
    extra usage     $5.93 of $100.00
  work   zach@company.example · Company Inc
    5h session      [█         ]  14%  resets 12:19pm
    7d all models   [          ]   2%  resets Mon 9:59pm
```

*Use it for:* two Claude subscriptions on one machine · checking which account
still has 5-hour budget left before you start a long task.

## Requirements

| Tool   | Required? | Why |
|--------|-----------|-----|
| bash 4+ | yes | the whole tool |
| jq     | yes | reads and rewrites Claude Code's JSON files |
| fzf    | picker only | `cswap` with no arguments |
| curl   | `--limits` only | talks to the usage endpoint |
| claude | `new` only | runs `claude auth logout` / `claude auth login` |
| security | macOS only | reads and writes the login Keychain item (ships with macOS) |

Linux and macOS both work; nothing here needs GNU coreutils. On macOS you do
need a newer bash than the 3.2 Apple ships:

```bash
brew install bash jq fzf
```

## Install

1. Clone somewhere stable:
   ```bash
   git clone https://github.com/orbxom/claude-session-swapper.git ~/repos/claude-session-swapper
   ```
2. Symlink the entrypoint onto your PATH:
   ```bash
   ln -s ~/repos/claude-session-swapper/cswap.sh ~/.local/bin/cswap
   ```
3. Save the login you're currently using:
   ```bash
   cswap add work
   ```
4. Add the second account. This logs you out, opens the browser login, and
   saves the result:
   ```bash
   cswap new personal
   ```

## Usage

```bash
cswap                    # fzf picker over saved profiles, ● marks the active one
cswap personal           # switch directly
cswap add work           # save the current live login as "work"
cswap add work --force   # overwrite an existing profile
cswap new personal       # save current, claude auth logout + login, save as "personal"
cswap list               # table of saved profiles
cswap status             # "work (zach@company.example)" / "unsaved login: …" / "not logged in"
cswap rm old --yes       # delete a saved profile (never touches the live login)
cswap --limits           # usage windows for every profile
cswap --limits work      # just one
cswap --limits --no-refresh   # don't refresh expired saved tokens
```

### Switching

Before restoring another profile, `cswap` always writes the live login back
into the profile it belongs to. Claude Code rotates the refresh token while it
runs, so a saved copy from an hour ago may already be dead. If the live login
matches no saved profile, the switch stops and tells you to `cswap add` it or
pass `--discard`.

Switching while a `claude` session is open is not blocked. The running session
keeps working with the tokens it has in memory, and if it refreshes them it
will write the *old* account's tokens over the new one. Close sessions first,
or accept that you may need to switch again.

### Limits

`cswap --limits` calls the same endpoint Claude Code's `/usage` uses. The
active profile is read with the live token. Other profiles use the token saved
in their profile, which is usually expired, so `cswap` refreshes it against
Claude Code's OAuth token endpoint and writes the new pair back into the
profile. The live token is never refreshed by `cswap`; if it has expired you'll
see `token expired (open claude to refresh)`.

## How it works

1. **Two live stores.** Claude Code keeps the OAuth tokens under
   `claudeAiOauth` in a JSON blob that lives either in the macOS login Keychain
   (item `Claude Code-credentials`, the default on a Mac) or in
   `~/.claude/.credentials.json` (Linux, and macOS when the Keychain is
   unavailable); the account identity sits in `~/.claude.json` under
   `oauthAccount` and `userID`. `cswap` looks for a live Keychain item first and
   falls back to the file, so it follows whichever one Claude Code is using —
   `cswap status` prints which. Both stores hold other things too (MCP tokens,
   the trusted-device token, UI state, per-project settings); `cswap` rewrites
   the login keys and nothing else.
2. **The desktop app has its own login.** `Claude.app` is an Electron shell
   around claude.ai, so it authenticates with a `sessionKey` cookie rather than
   the OAuth blob. `cswap` swaps that too: its `Cookies` database, the three
   account keys in `config.json`, and this account's entry in
   `ant-device-registry.json`. The encrypted values move verbatim — they are
   encrypted with an app-wide key, not a per-account one, so `cswap` never
   decrypts anything and never prompts for Keychain access. **Quit the app
   before switching**: Electron rewrites its login on exit, so `cswap` refuses
   while it is running. Set `CSWAP_NO_DESKTOP=1` to switch only the CLI login.
3. **A profile is a directory** at `~/.config/cswap/profiles/<name>/` holding
   one JSON file per *slot*: `login.json` for Claude Code, `desktop.json` for
   the desktop app when it is installed. Files are 0600, directories 0700.
4. **Capture** reads the three keys out of the live stores and writes
   `login.json` atomically (temp file in the same dir, then `mv`).
5. **Restore** merges the three keys back with `jq`, leaving every other key
   untouched — atomically for the file, and for the Keychain with the same
   in-place `security add-generic-password -U` that Claude Code itself uses, so
   the item keeps its ACL and the tokens beside the login survive. `cswap` never
   deletes the Keychain item.
6. **Active profile is derived, not stored.** The live `accountUuid` is
   compared with each profile's saved one. There is no pointer file to go stale
   when you log in or out outside `cswap`.
7. **Slots are the extension point.** `cswap-lib.sh` has a `SLOTS` array and a
   four-function contract per slot (capture, restore, identity, identity_of).
   Swapping settings or plugins later means adding a slot; `cswap.sh` never
   names one. A slot may also define a `preflight` that refuses the whole
   command before anything is written — that is how the desktop slot stops a
   switch while the app is open, rather than leaving half your session on one
   account and half on the other.

## Files

| Path | Purpose |
|------|---------|
| `cswap.sh` | Entrypoint. Arg parsing, `add`/`new`/`list`/`status`/`rm`/switch/picker. Symlink this onto PATH. |
| `cswap-lib.sh` | Sourced by both scripts: paths, atomic JSON writes, slot registry, `login` slot, profile helpers. |
| `cswap-limits.sh` | `--limits`: token selection, refresh-if-expired, usage fetch, rendering. |
| `*.test.sh` | One test file per script. |
| `test/run.sh` | Runs every `*.test.sh`; non-zero if any fail. |
| `docs/superpowers/specs/` | Design notes. |

## Running the tests

```bash
bash test/run.sh          # everything
bash cswap.test.sh        # one file
```

Tests never touch your real files or the network: they point `CSWAP_HOME` and
`CLAUDE_CONFIG_DIR` at temp dirs, stub `claude` on PATH, and replace curl via
`CSWAP_CURL`. Never run a test file with those variables already exported to
real locations.

## Limitations

- Refresh tokens last about 30 days. A profile you haven't switched to (or
  checked with `--limits`) in a month will need `claude auth login` again:
  switch to it, log in, and the next switch away saves the fresh tokens.
- `cswap` does not check for running `claude` sessions. See *Switching* above.
  It does check for the desktop app, and refuses to switch while it is open.
- The desktop app's conversation cache and window state are not per-account.
  Only the login is swapped, so the sidebar may briefly show the previous
  account's history until it refreshes.
- Only the login is swapped. Settings, plugins, and history are shared. A
  settings/plugins slot is planned; the slot contract in `cswap-lib.sh` is
  where it goes.
- The desktop app's Keychain item, service names and config keys were read out
  of the app, not a published API, and may change.
- The usage and token endpoints, and the Keychain service and account names,
  are the ones Claude Code itself uses, read out of the binary. They are not a
  published API and may change.
- If two profiles hold the same account, only the first alphabetically shows ●.

## License

MIT — see `LICENSE`.
