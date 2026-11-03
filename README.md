# tmux-surikat

*tmux-surikat keeps watch over your Claude Code sessions.* **surikat** is
Swedish for meerkat (suricate).

When you run many Claude Code sessions in tmux, it's hard to see which ones
need you. surikat shows each session's state as an icon in the tmux status
bar, lets you jump to the next waiting session with one key, and gives you a
popup dashboard with a live preview.

```
 🔴 🟢 3:api   ⚙ 4:web   5:notes                          🔴1 🟢1  14:02
```

This is **not a TPM plugin**. It installs with `./install.sh`, which also adds
hooks to Claude Code's settings (`~/.claude/settings.json`). Everything is
backed up first and `./install.sh --uninstall` reverses it.

## Features

| Key / command | What it does |
|---|---|
| status bar | An icon per Claude pane in front of each window name, e.g. `🔴 🟢 3:api`. |
| `status-right` | A summary such as `🔴2 ❓1 🟡1 🟢5`; empty when nothing is waiting. |
| `prefix C` | Dashboard popup (fzf): sessions sorted by urgency, live pane preview. `enter` jumps, `ctrl-x` marks 🟢/🟡 as seen, `ctrl-r` reloads, `esc` closes. |
| `prefix N` | Jump to the most urgent, longest-waiting session. Press again for the next one (wraps around). |
| `prefix P` | Jump back along your trail (last 20 jumps), skipping panes that are gone. |
| `prefix T` | `choose-tree` with icons. `prefix w` stays the stock tree. |
| `surikat --watch` | Full-screen live table, e.g. for a dedicated window. |
| `surikat --list` / `--count` / `--gc` | Print the table, print the summary, clean up. |

### States

| Icon | State | Meaning |
|---|---|---|
| 🔴 | `perm` | Waiting for a permission approval |
| ❓ | `ask` | Claude asked you a question |
| 🟡 | `idle` | Waiting after an interrupt (Esc) or an API error |
| 🟢 | `done` | Turn finished, waiting for a follow-up |
| ⚙ | `running` | Working |
| ⚪ | `ready` | New session, or marked as seen (dashboard only) |

`prefix N` visits 🔴/❓ first, then 🟡, then 🟢, oldest wait first.

## Requirements

- **Linux or macOS**, any terminal, tmux local or on a remote machine over
  ssh (surikat runs where tmux and Claude Code run; nothing is needed on the
  other side). Your login shell doesn't matter (bash, zsh, fish, …).
- tmux ≥ 3.2
- bash ≥ 3.2 (macOS's `/bin/bash` is fine)
- jq ≥ 1.6
- fzf (only for the `prefix C` dashboard)
- Claude Code with the `PermissionRequest`, `StopFailure` and
  `PostToolUseFailure` hooks

```sh
brew install tmux jq fzf          # macOS
sudo apt install tmux jq fzf      # Debian/Ubuntu
```

## Install

```sh
git clone <this repo> ~/code/tmux-surikat
cd ~/code/tmux-surikat
./install.sh --dry-run   # see what would change
./install.sh
```

The installer:

- links `surikat`, `surikat-hook` and `surikat-tmux` into `~/.local/bin`
  (`--copy` copies them instead), so `git pull` updates them;
- links `tmux/surikat.conf` to `~/.tmux/surikat.conf` and appends one line,
  `source-file -q ~/.tmux/surikat.conf`, to `~/.tmux.conf`;
- merges the hook entries into `~/.claude/settings.json`, keeping all your
  other settings and hooks;
- loads `surikat.conf` into a running tmux server.

Every changed file is backed up as `<file>.bak.<timestamp>`. Running Claude
sessions pick up the hooks with their next event; no restart needed.

Overrides: `BIN_DIR`, `TMUX_CONF`, `CLAUDE_SETTINGS`.

### Uninstall

```sh
./install.sh --uninstall
```

This removes the hooks, the scripts, the tmux line (your `.tmux.conf` ends up
byte-identical), the key bindings and formats from the running server, and
this host's state. Backups are kept.

## How it works

```
Claude Code hook (JSON on stdin)
  └─ surikat-hook <event>
       ├─ writes  $STATE_DIR/<session_id>.json   (atomic: tmp + mv)
       └─ sets    tmux pane option @surikat=<state>

tmux (surikat.conf → surikat-tmux)
  ├─ window formats: #{E:@surikat_window_icons} = #{P:#{E:@surikat_pane_icon}}
  ├─ status-right:   #(surikat --count)   every 5s
  └─ keys C / N / P / T → surikat / choose-tree
```

| Claude Code event | Hook argument | Effect |
|---|---|---|
| `SessionStart` | `start` | ⚪ (a compaction keeps the current state) |
| `UserPromptSubmit` | `prompt` | ⚙, remembers the prompt |
| `PostToolUse`, `PostToolUseFailure` | `tool` | ⚙ (a subagent's tool doesn't clear a pending 🔴/❓) |
| `PermissionRequest` | `perm` | 🔴, or ❓ for `AskUserQuestion` |
| `Notification` | `notify` | 🔴 for permission prompts; 🟡 for `idle_prompt` after an interrupt |
| `Stop` | `stop` | 🟢 |
| `StopFailure` | `fail` | 🟡 |
| `SessionEnd` | `end` | removes the record |

State lives in `${XDG_STATE_HOME:-~/.local/state}/surikat/<short-hostname>/`,
one JSON file per session; per host, so a shared (NFS) `$HOME` works.
Records are garbage-collected when their pane is gone (judged only for the
tmux server they belong to), when the Claude process has exited, or after 24
hours without events while running/ready.

The hook never prints anything, always exits 0 and takes roughly 50–80ms.

## Development

```sh
tests/run.sh               # unit/integration tests on a private tmux server
tests/sandbox-install.sh   # install.sh against a throwaway HOME
shellcheck bin/* install.sh tests/*.sh
```

The tests never touch your real tmux server or state. Environment overrides
for experiments: `SURIKAT_DIR` (state dir), `SURIKAT_STALE_HOURS`,
`SURIKAT_INTERVAL` (`--watch`), `SURIKAT_BIN` (path used in status-right).

Portability rules for contributors: bash 3.2, no `/proc`, no GNU-only tool
flags (`sed -i`, `readlink -f`, `stat -c`, `date -d`, `timeout`, …), and keep
the fzf command strings plain so they work in any `$SHELL`.

See [TESTING.md](TESTING.md) for the manual checklist.

## Known limitations

- A denied permission request has no event of its own; 🔴 clears with the
  next tool event, prompt or turn end.
- After an interrupt (Esc), Claude Code sends no `Stop`; the session turns 🟡
  only when the `idle_prompt` notification arrives about 60s later.
- While a permission dialog is open, a parallel main-agent tool finishing can
  clear 🔴 for a few seconds until the permission notification sets it again.
- The dashboard doesn't auto-refresh (`ctrl-r` reloads; use `surikat
  --watch` for a live view), because refreshing fzf 0.29 can make Enter jump
  to the wrong row.
- With several clients attached, the dashboard acts for the most recently
  active client.
- Emoji widths depend on your terminal and font.
- No notifications outside tmux (bell, desktop, push) by design: they depend
  on the terminal, OS or an external service.
