#!/usr/bin/env bash
# tests/sandbox-install.sh: run install.sh against a throwaway HOME and a
# private tmux server. Never touches the real HOME or tmux server.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REAL_TMUX=$(command -v tmux) || {
  echo "tmux not found"
  exit 1
}
# Short path: macOS limits unix socket paths to 104 bytes.
T=$(mktemp -d /tmp/sks.XXXXXX)
REAL_HOME=$HOME
export HOME=$T/home TMUX_TMPDIR=$T
mkdir -p "$HOME/.claude" "$T/shim"
cat >"$T/shim/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L sandbox "\$@"
EOF
chmod +x "$T/shim/tmux"
export PATH="$T/shim:$PATH"
unset TMUX TMUX_PANE XDG_STATE_HOME SURIKAT_DIR BIN_DIR TMUX_CONF CLAUDE_SETTINGS

cleanup() {
  tmux kill-server 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

pass=0 failed=0
check() {
  local name=$1
  shift
  if "$@"; then
    pass=$((pass + 1))
    echo "ok   $name"
  else
    failed=$((failed + 1))
    echo "FAIL $name"
  fi
}

# A user config with its own styling, and settings with a foreign hook.
cat >"$HOME/.tmux.conf" <<'EOF'
set -g prefix C-a
set -g status-right "%H:%M"
set -g window-status-format "#[fg=red]#I:#W"
EOF
cp "$HOME/.tmux.conf" "$T/tmux.conf.orig"
cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "theme": "dark",
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
  }
}
EOF
cp "$HOME/.claude/settings.json" "$T/settings.orig"

tmux -f "$HOME/.tmux.conf" new-session -d -s main -x 200 -y 50

"$REPO/install.sh" --dry-run >"$T/dry.out" 2>&1
check "dry run writes nothing" cmp -s "$HOME/.tmux.conf" "$T/tmux.conf.orig"
check "dry run leaves settings alone" cmp -s "$HOME/.claude/settings.json" "$T/settings.orig"
check "dry run shows a diff" grep -q '^+source-file -q' "$T/dry.out"

"$REPO/install.sh" >"$T/install1.out" 2>&1
check "install succeeds" test $? -eq 0
"$REPO/install.sh" >"$T/install2.out" 2>&1
check "second install succeeds" test $? -eq 0
check "second install changes nothing" sh -c "! grep -qE 'linked|added|updated|backup' '$T/install2.out'"

S=$HOME/.claude/settings.json
check "foreign hook kept" test "$(jq '[.hooks.Stop[].hooks[] | select(.command == "say done")] | length' "$S")" = 1
check "theme kept" test "$(jq -r .theme "$S")" = dark
check "one surikat handler per event" test "$(jq '[.hooks[][] .hooks[] | select(.command | test("surikat-hook"))] | length' "$S")" = 9
# shellcheck disable=SC2088 # the literal ~ is what we expect
check "hook command uses literal ~" test "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$S")" = "~/.local/bin/surikat-hook start"
check "settings backup exists" sh -c "ls '$S'.bak.* >/dev/null 2>&1"

check "scripts are symlinks into the repo" test "$(readlink "$HOME/.local/bin/surikat")" = "$REPO/bin/surikat"
check "conf is a symlink" test -L "$HOME/.tmux/surikat.conf"
check "source line added once" test "$(grep -cxF 'source-file -q ~/.tmux/surikat.conf' "$HOME/.tmux.conf")" = 1
check "tmux.conf backup exists" sh -c "ls '$HOME/.tmux.conf'.bak.* >/dev/null 2>&1"

check "prefix C bound to the dashboard" sh -c "tmux list-keys -T prefix C | grep -q surikat"
check "prefix N bound" sh -c "tmux list-keys -T prefix N | grep -q 'surikat --next'"
check "prefix T bound" sh -c "tmux list-keys -T prefix T | grep -q choose-tree"
check "prefix w untouched" sh -c "tmux list-keys -T prefix w | grep -q 'choose-tree -Zw\$'"
wsf=$(tmux show -gv window-status-format)
check "icons prepended, user styling kept" test "$wsf" = '#{E:@surikat_window_icons}#[fg=red]#I:#W'
check "summary appended once" test "$(tmux show -gv status-right)" = '%H:%M #(~/.local/bin/surikat --count)'

# Re-sourcing the user's config runs surikat-tmux again: no duplicates.
tmux source-file "$HOME/.tmux.conf"
tmux source-file "$HOME/.tmux.conf"
check "re-source: status-right not duplicated" test "$(tmux show -gv status-right)" = '%H:%M #(~/.local/bin/surikat --count)'
check "re-source: icons not duplicated" test "$(tmux show -gv window-status-format)" = '#{E:@surikat_window_icons}#[fg=red]#I:#W'

mkdir -p "$HOME/.local/state/surikat/x" # state dir from use
host=${HOSTNAME:-$(hostname)}
host=${host%%.*}
mkdir -p "$HOME/.local/state/surikat/$host"
echo '{}' >"$HOME/.local/state/surikat/$host/s.json"

"$REPO/install.sh" --uninstall >"$T/uninstall.out" 2>&1
check "uninstall succeeds" test $? -eq 0
check "tmux.conf byte-identical" cmp -s "$HOME/.tmux.conf" "$T/tmux.conf.orig"
check "settings back to the original" test "$(jq -S . "$S")" = "$(jq -S . "$T/settings.orig")"
check "scripts removed" test ! -e "$HOME/.local/bin/surikat" -a ! -e "$HOME/.local/bin/surikat-hook"
check "conf removed" test ! -e "$HOME/.tmux/surikat.conf"
check "this host's state removed" test ! -e "$HOME/.local/state/surikat/$host"
check "other hosts' state kept" test -d "$HOME/.local/state/surikat/x"
check "bindings removed" sh -c "! tmux list-keys -T prefix N >/dev/null 2>&1"
check "prefix C restored" sh -c "tmux list-keys -T prefix C | grep -q customize-mode"
check "formats restored" test "$(tmux show -gv window-status-format)" = '#[fg=red]#I:#W'
check "status-right restored" test "$(tmux show -gv status-right)" = '%H:%M'

# --copy, and a tmux.conf that doesn't exist yet.
rm -f "$HOME/.tmux.conf"
"$REPO/install.sh" --copy >"$T/copy.out" 2>&1
check "--copy installs regular files" test -f "$HOME/.local/bin/surikat" -a ! -L "$HOME/.local/bin/surikat"
check "--copy creates tmux.conf" grep -qxF 'source-file -q ~/.tmux/surikat.conf' "$HOME/.tmux.conf"
"$REPO/install.sh" --uninstall >/dev/null 2>&1
check "uninstall removes a tmux.conf it created" test ! -e "$HOME/.tmux.conf"
check "uninstall removes copies" test ! -e "$HOME/.local/bin/surikat"

# The Claude Code plugin provides the hooks: install leaves them out, and
# drops ones from an earlier install.sh run.
"$REPO/install.sh" >/dev/null 2>&1
jq '.enabledPlugins = {"surikat@tmux-surikat": true}' "$S" >"$T/s.json" && mv "$T/s.json" "$S"
"$REPO/install.sh" >"$T/plugin.out" 2>&1
check "plugin enabled: install succeeds" test $? -eq 0
check "plugin enabled: says why" grep -q 'plugin is enabled' "$T/plugin.out"
check "plugin enabled: no surikat hooks in settings" test "$(jq '[.hooks // {} | .[][] .hooks[] | select(.command | test("surikat-hook"))] | length' "$S")" = 0
check "plugin enabled: tmux side still installed" grep -qxF 'source-file -q ~/.tmux/surikat.conf' "$HOME/.tmux.conf"
"$REPO/install.sh" --uninstall >/dev/null 2>&1

# Invalid settings: refuse, change nothing.
echo '{ not json' >"$S"
"$REPO/install.sh" >"$T/bad.out" 2>&1
check "invalid settings.json refused" test $? -ne 0
check "invalid settings.json untouched" test "$(cat "$S")" = '{ not json'

[ "$HOME" != "$REAL_HOME" ] || exit 1
echo
echo "$pass passed, $failed failed"
[ $failed = 0 ]
