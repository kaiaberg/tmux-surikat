# tmux-surikat

*tmux-surikat keeps watch over your Claude Code sessions.* **surikat** is
Swedish for meerkat (suricate).

When you run many Claude Code sessions in tmux, it's hard to see which ones
need you. surikat shows each session's state as an icon in the tmux status
bar, lets you jump to the next waiting session with one key, and gives you a
popup dashboard with a live preview.

```
 ● ✓ 3:api   ◌ 4:web   5:notes                              ●1 ✓1  14:02
```

The glyphs are colored (red, green, dim, …); see [Look](#look) for Nerd
Font icons, emoji and your own colors.

surikat only watches. Unlike session managers such as claude-squad, it
doesn't start, wrap or arrange your sessions, so it fits the tmux layout you
already have. It has two halves: Claude Code hooks that record each
session's state, and a tmux side that shows it. [Install](#install) them
with TPM and the Claude Code plugin, or with `./install.sh`.

## Features

Keys are the defaults; see [Keys](#keys) to change them.

| Key / command | What it does |
|---|---|
| status bar | An icon per Claude pane in front of each window name, e.g. `● ✓ 3:api`. |
| `status-right` | A summary such as `●2 ◆1 ◐1 ✓5`; empty when nothing is waiting. |
| `prefix C` | Dashboard popup (fzf): sessions [sorted](#sort-order), live pane preview. `enter` jumps, `ctrl-f` toggles ★ favorite, `ctrl-l` toggles ↓ sidelined, `ctrl-o` flips the wait-time order, `ctrl-x` marks ✓/◐ as seen, `ctrl-r` reloads, `esc` closes. The selection wraps around at the top and bottom. |
| `prefix N` | Jump to the most urgent, longest-waiting session, skipping sidelined ones. Press again for the next one (wraps around). |
| `prefix P` | Jump back along your trail (last 20 jumps), skipping panes that are gone. |
| `prefix T` | `choose-tree` with icons and ★/↓ marks. `prefix w` stays the stock tree. |
| `surikat --watch` | Full-screen live table, e.g. for a dedicated window. |
| `surikat --list` / `--count` / `--gc` | Print the table, print the summary, clean up. |
| `surikat --fav` / `--side [PANE]` | Toggle a pane (default: the current one) as favorite / sidelined. |

### States

| Glyph | Emoji | State | Meaning |
|---|---|---|---|
| `●` red | 🔴 | `perm` | Waiting for a permission approval |
| `◆` magenta | ❓ | `ask` | Claude asked you a question |
| `◐` yellow | 🟡 | `idle` | Waiting after an interrupt (Esc) or an API error |
| `✓` green | 🟢 | `done` | Turn finished, waiting for a follow-up |
| `◌` dim | ⚙ | `running` | Working |
| `○` dim | ⚪ | `ready` | New session, or marked as seen (dashboard only) |

`prefix N` visits ●/◆ first, then ◐, then ✓, oldest wait first.

### Keys

All four keys are in the prefix table. Change them in `~/.tmux.conf`:

```tmux
set -g @surikat_key_dashboard D   # default C (replaces customize-mode)
set -g @surikat_key_next N
set -g @surikat_key_back P
set -g @surikat_key_tree none     # '' or none: don't bind this one
```

Whatever a key did before is restored when surikat moves off it or is
uninstalled.

In the dashboard the wait time is dim for the first 5 minutes and turns bold
red after an hour.

### Look

Set these and the [keys](#keys) in `~/.tmux.conf` *before* surikat loads
(the `source-file … surikat.conf` line, or TPM's `run` line at the end), or
reload the config after changing them:

```tmux
set -g @surikat_style glyph        # glyph (default), nerd or emoji
set -g @surikat_color_perm 'fg=red,bold'
set -g @surikat_color_done colour108
```

- `glyph` uses plain Unicode shapes and works with any font.
- `nerd` uses Nerd Font icons (lock, question, pause, check, cog, circle).
  Without a Nerd Font they show as boxes.
- `emoji` is the old look; colors don't apply to it.

Colors are tmux styles (`fg=…`, `bold`, `dim`, …) or a bare color (`red`,
`brightblue`, `colour208`, `#ff8000`). The names are `perm`, `ask`, `idle`,
`done`, `running`, `ready` and the marks `fav` and `side`. The 16 named colors
follow your terminal's color scheme. The dashboard turns them into ANSI
colors, so a color override applies there too.

### Sort order

The dashboard, `--list` and `--watch` sort by:

1. urgency: ●/◆ → ◐ → ✓ → ◌ → ○
2. mark: ★ favorite → unmarked → ↓ sidelined (shown dimmed)
3. wait time: shortest first by default

Only the wait-time direction can change. `ctrl-o` flips it while the
dashboard is open, and the default is set in `~/.tmux.conf`:

```tmux
set -g @surikat_order desc   # longest wait first (default: asc)
```

`prefix N` always goes oldest first, favorites before unmarked sessions
within a state. Sidelined sessions are skipped by `prefix N` and not counted
in `status-right`.

Marks are kept as a pane option (`@surikat_mark`), so they survive `/clear`
and restarting Claude in the same pane, but not a tmux server restart. To mark
the current pane without opening the dashboard, bind keys of your own, e.g.:

```tmux
bind F run-shell "~/.local/bin/surikat --fav '#{pane_id}'"
bind S run-shell "~/.local/bin/surikat --side '#{pane_id}'"
```

## Requirements

- **Linux or macOS**, any terminal, tmux local or on a remote machine over
  ssh (surikat runs where tmux and Claude Code run; nothing is needed on the
  other side). Your login shell doesn't matter (bash, zsh, fish, …).
- tmux ≥ 3.2
- bash ≥ 3.2 (macOS's `/bin/bash` is fine)
- jq ≥ 1.6
- fzf ≥ 0.29 (only for the `prefix C` dashboard). With fzf ≥ 0.40 the
  header shows the current wait-time order, and with fzf ≥ 0.71 the cursor
  stays on the same session when the list reloads.
- Claude Code with the `PermissionRequest`, `StopFailure` and
  `PostToolUseFailure` hooks

```sh
brew install tmux jq fzf          # macOS
sudo apt install tmux jq fzf      # Debian/Ubuntu
```

## Install

surikat needs both halves: the hooks in Claude Code and the tmux side.
Install them with the plugin managers you already use, or both at once with
`install.sh`.

### With TPM and the Claude Code plugin

The tmux side, with [TPM](https://github.com/tmux-plugins/tpm): add this to
`~/.tmux.conf` and press `prefix I`:

```tmux
set -g @plugin 'kaiaberg/tmux-surikat'
```

The hooks, in Claude Code:

```
/plugin install surikat --marketplace kaiaberg/tmux-surikat
```

On older Claude Code versions, run `/plugin marketplace add
kaiaberg/tmux-surikat` and then `/plugin install surikat@tmux-surikat`.
Restart running Claude sessions to load the hooks.

The `surikat` command (`--list`, `--watch`, …) is then in
`~/.tmux/plugins/tmux-surikat/bin`; link it onto your `PATH` if you want it:

```sh
ln -s ~/.tmux/plugins/tmux-surikat/bin/surikat ~/.local/bin/
```

To uninstall, run `/plugin uninstall surikat@tmux-surikat` in Claude Code,
then `~/.tmux/plugins/tmux-surikat/bin/surikat-tmux --remove`, then remove
the `@plugin` line and press `prefix alt-u`. State is kept in
`~/.local/state/surikat`; delete it if you like.

### With install.sh

```sh
git clone https://github.com/kaiaberg/tmux-surikat ~/code/tmux-surikat
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
  other settings and hooks (unless the Claude Code plugin is enabled, which
  already provides them; both would run every hook twice);
- loads `surikat.conf` into a running tmux server.

Every changed file is backed up as `<file>.bak.<timestamp>`. Running Claude
sessions pick up the hooks with their next event; no restart needed.

Overrides: `BIN_DIR`, `TMUX_CONF`, `CLAUDE_SETTINGS`.

To uninstall:

```sh
./install.sh --uninstall
```

This removes the hooks, the scripts, the tmux line (your `.tmux.conf` ends up
byte-identical), the key bindings and formats from the running server, and
this host's state. Backups are kept.

### What it changes in tmux

However you install it, surikat:

- prepends `#{E:@surikat_window_icons}` to `window-status-format` and
  `window-status-current-format`, keeping your own styling;
- appends the summary, `#(surikat --count)`, to `status-right`;
- raises `status-right-length` to 80 if it is lower, and sets
  `status-interval` to 5 if it is 0 or higher, so the summary stays current;
- binds the four [keys](#keys).

`surikat-tmux --remove` (run by `./install.sh --uninstall`) restores all of
it.

## How it works

```
Claude Code hook (JSON on stdin)
  └─ surikat-hook <event>
       ├─ writes  $STATE_DIR/<session_id>.json   (atomic: tmp + mv)
       └─ sets    tmux pane option @surikat=<state>

tmux (surikat.conf or surikat.tmux → surikat-tmux)
  ├─ window formats: #{E:@surikat_window_icons} = #{P:#{E:@surikat_pane_icon}}
  ├─ status-right:   #(surikat --count)   every 5s
  └─ keys C / N / P / T → surikat / choose-tree
```

| Claude Code event | Hook argument | Effect |
|---|---|---|
| `SessionStart` | `start` | ○ (a compaction keeps the current state) |
| `UserPromptSubmit` | `prompt` | ◌, remembers the prompt |
| `PostToolUse`, `PostToolUseFailure` | `tool` | ◌ (a subagent's tool doesn't clear a pending ●/◆) |
| `PermissionRequest` | `perm` | ●, or ◆ for `AskUserQuestion` |
| `Notification` | `notify` | ● for permission prompts; ◐ for `idle_prompt` after an interrupt |
| `Stop` | `stop` | ✓ |
| `StopFailure` | `fail` | ◐ |
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
shellcheck bin/* install.sh tests/*.sh surikat.tmux
```

CI runs all three on Ubuntu 22.04 (the minimum versions), the latest Ubuntu
and macOS (with `/bin/bash` 3.2). The tests never touch your real tmux server or state. Environment overrides
for experiments: `SURIKAT_DIR` (state dir), `SURIKAT_STALE_HOURS`,
`SURIKAT_INTERVAL` (`--watch`), `SURIKAT_BIN` (path used in status-right
and the key bindings),
`SURIKAT_ORDER` (`asc`/`desc`, overrides `@surikat_order`), `SURIKAT_STYLE`
(overrides `@surikat_style`).

Portability rules for contributors: bash 3.2, no `/proc`, no GNU-only tool
flags (`sed -i`, `readlink -f`, `stat -c`, `date -d`, `timeout`, …), and keep
the fzf command strings plain so they work in any `$SHELL`.

The hook events are listed twice: `EVENTS` in `install.sh` and
`hooks/hooks.json` for the plugin. `tests/run.sh` checks that they match.

See [TESTING.md](TESTING.md) for the manual checklist.

## Known limitations

- A denied permission request has no event of its own; ● clears with the
  next tool event, prompt or turn end.
- After an interrupt (Esc), Claude Code sends no `Stop`; the session turns ◐
  only when the `idle_prompt` notification arrives about 60s later.
- While a permission dialog is open, a parallel main-agent tool finishing can
  clear ● for a few seconds until the permission notification sets it again.
- The dashboard doesn't auto-refresh (`ctrl-r` reloads; use `surikat
  --watch` for a live view), because refreshing fzf 0.29 can make Enter jump
  to the wrong row.
- With several clients attached, the dashboard acts for the most recently
  active client.
- Emoji widths depend on your terminal and font.
- No notifications outside tmux (bell, desktop, push) by design: they depend
  on the terminal, OS or an external service.

## License

MIT; see [LICENSE](LICENSE).
