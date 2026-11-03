# Testing

## Automated

```sh
tests/run.sh               # private tmux server, temp state
tests/sandbox-install.sh   # install.sh against a throwaway HOME + tmux server
shellcheck bin/* install.sh tests/*.sh
```

Run them on Linux and on macOS (with `/bin/bash` 3.2) when you can. Neither
touches your real tmux server, `~/.tmux.conf`, `~/.claude/settings.json` or
state directory.

## Manual end-to-end checklist

Run this after a real install. `prefix` is your tmux prefix.

1. `./install.sh --dry-run && ./install.sh`. The backups exist, the status bar
   looks unchanged, and `prefix N` says "no Claude session is waiting".
2. Start a scratch session in a split (`cd "$(mktemp -d)" && claude`). It is
   ⚪ in `surikat --list`.
3. Ask for `ls`, then switch away: ⚙, then 🟢.
4. Ask it to `touch x.txt`: 🔴. `prefix N` jumps there and `prefix P` jumps
   back. Approve: ⚙ → 🟢. Deny: 🔴 clears.
5. Interrupt with Esc and wait about 60s: 🟡.
6. Two Claude panes in one window show both icons.
7. Have Claude ask a question: ❓; answering → ⚙. With several sessions
   waiting, `prefix N` cycles and wraps, and `prefix P` retraces.
8. `prefix C`: sorted rows, preview, Enter, `ctrl-x`, Esc. `prefix T` shows
   icons; `prefix w` is unchanged.
9. `/exit` removes the entry. After `kill-pane`, the entry is gone within
   about 5s.
10. Re-source the tmux config twice: no errors, no duplicates.
11. `./install.sh --uninstall`: icons, summary and bindings are gone, and
    `~/.tmux.conf` matches its backup.
