#!/usr/bin/env bash
# install.sh: install, update or uninstall surikat.
#
#   ./install.sh               install or update (symlinks into this repo)
#   ./install.sh --copy        install copies instead of symlinks
#   ./install.sh --dry-run     show what would change, write nothing
#   ./install.sh --uninstall   undo everything (keeps backups)
#
# Overrides: BIN_DIR, TMUX_CONF, CLAUDE_SETTINGS, SURIKAT_DIR.
# Every file that is changed is first backed up as <file>.bak.<timestamp>.

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd -P)
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
TMUX_CONF=${TMUX_CONF:-$HOME/.tmux.conf}
CLAUDE_SETTINGS=${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}
CONF_DIR=$HOME/.tmux
CONF=$CONF_DIR/surikat.conf
host=${HOSTNAME:-$(hostname)}
host=${host%%.*}
STATE_DIR=${SURIKAT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/surikat/$host}
SCRIPTS="surikat surikat-hook surikat-tmux"
STAMP=$(date +%Y%m%d-%H%M%S)

COMMENT="# surikat: Claude Code session status (added by tmux-surikat/install.sh)"
# shellcheck disable=SC2088
SOURCE_LINE="source-file -q ~/.tmux/surikat.conf"

EVENTS='[["SessionStart","start"],["UserPromptSubmit","prompt"],
  ["PostToolUse","tool"],["PostToolUseFailure","tool"],
  ["PermissionRequest","perm"],["Notification","notify"],
  ["Stop","stop"],["StopFailure","fail"],["SessionEnd","end"]]'

if [ "$BIN_DIR" = "$HOME/.local/bin" ]; then
  # shellcheck disable=SC2088
  HOOK_CMD="~/.local/bin/surikat-hook" # the hook shell expands ~
else
  HOOK_CMD="$BIN_DIR/surikat-hook"
fi

mode=install copy=0 dry=0
for a in "$@"; do
  case $a in
    --copy) copy=1 ;;
    --dry-run | -n) dry=1 ;;
    --uninstall) mode=uninstall ;;
    -h | --help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "install.sh: unknown option: $a" >&2
      exit 2
      ;;
  esac
done

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
# Run a command, or only describe it with --dry-run.
run() {
  if [ $dry = 1 ]; then
    say "  would run: $*"
  else
    "$@"
  fi
}
backup() {
  [ -e "$1" ] || return 0
  if [ $dry = 1 ]; then
    say "  would back up $1 -> $1.bak.$STAMP"
  else
    cp -p "$1" "$1.bak.$STAMP"
    say "  backup: $1.bak.$STAMP"
  fi
}
# Replace $1 with the contents of $2, keeping $1's mode.
replace() {
  local dest=$1 src=$2 tmp
  tmp=$dest.tmp.$$
  if [ -e "$dest" ]; then cp -p "$dest" "$tmp"; else : >"$tmp"; fi
  cat "$src" >"$tmp"
  mv -f "$tmp" "$dest"
}
tmux_running() { command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/surikat-install.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# --- requirements ------------------------------------------------------------

check_requirements() {
  command -v jq >/dev/null 2>&1 || die "jq is required (e.g. apt install jq / brew install jq)"
  command -v tmux >/dev/null 2>&1 || die "tmux >= 3.2 is required"
  local v
  v=$(tmux -V | sed 's/[^0-9.]//g')
  awk -v v="$v" 'BEGIN { split(v, a, "."); exit !((a[1] + 0) > 3 || ((a[1] + 0) == 3 && (a[2] + 0) >= 2)) }' ||
    die "tmux >= 3.2 is required (found $(tmux -V))"
  command -v fzf >/dev/null 2>&1 ||
    warn "fzf not found: the dashboard (prefix C) needs it; everything else works without it"
}

# --- scripts -----------------------------------------------------------------

install_scripts() {
  say "scripts -> $BIN_DIR"
  [ -d "$BIN_DIR" ] || run mkdir -p "$BIN_DIR"
  local s src dest
  for s in $SCRIPTS; do
    src=$REPO/bin/$s
    dest=$BIN_DIR/$s
    if [ $copy = 0 ]; then
      if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
        say "  $s: up to date"
        continue
      fi
      if [ -f "$dest" ] && [ ! -L "$dest" ] && ! cmp -s "$src" "$dest"; then
        backup "$dest"
      fi
      run ln -sfn "$src" "$dest"
      say "  $s: linked"
    else
      if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest"; then
        say "  $s: up to date"
        continue
      fi
      if [ -f "$dest" ] && [ ! -L "$dest" ]; then backup "$dest"; fi
      run rm -f "$dest"
      run cp "$src" "$dest"
      run chmod 755 "$dest"
      say "  $s: copied"
    fi
  done
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on PATH; add it to use 'surikat' from your shell" ;;
  esac
}

uninstall_scripts() {
  say "scripts in $BIN_DIR"
  local s src dest
  for s in $SCRIPTS; do
    src=$REPO/bin/$s
    dest=$BIN_DIR/$s
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
      run rm -f "$dest"
      say "  $s: removed"
    elif [ -f "$dest" ] && cmp -s "$src" "$dest"; then
      run rm -f "$dest"
      say "  $s: removed"
    elif [ -e "$dest" ] || [ -L "$dest" ]; then
      warn "$dest is not from this repo; left in place"
    fi
  done
}

# --- tmux --------------------------------------------------------------------

# The conf as it should be installed: a symlink for the default BIN_DIR,
# a copy with the paths rewritten otherwise (or with --copy).
install_tmux_conf() {
  say "tmux config -> $CONF"
  [ -d "$CONF_DIR" ] || run mkdir -p "$CONF_DIR"
  local src=$REPO/tmux/surikat.conf
  if [ $copy = 0 ] && [ "$BIN_DIR" = "$HOME/.local/bin" ]; then
    if [ -L "$CONF" ] && [ "$(readlink "$CONF")" = "$src" ]; then
      say "  surikat.conf: up to date"
    else
      if [ -f "$CONF" ] && [ ! -L "$CONF" ]; then backup "$CONF"; fi
      run ln -sfn "$src" "$CONF"
      say "  surikat.conf: linked"
    fi
  else
    sed "s#~/.local/bin#$BIN_DIR#g" "$src" >"$TMPD/surikat.conf"
    if [ -f "$CONF" ] && [ ! -L "$CONF" ] && cmp -s "$TMPD/surikat.conf" "$CONF"; then
      say "  surikat.conf: up to date"
    else
      if [ -f "$CONF" ] && [ ! -L "$CONF" ]; then backup "$CONF"; fi
      run rm -f "$CONF"
      run cp "$TMPD/surikat.conf" "$CONF"
      say "  surikat.conf: written"
    fi
  fi

  say "source line -> $TMUX_CONF"
  if [ -f "$TMUX_CONF" ] && grep -qxF "$SOURCE_LINE" "$TMUX_CONF"; then
    say "  up to date"
  else
    local new=$TMPD/tmux.conf
    if [ -s "$TMUX_CONF" ]; then
      cat "$TMUX_CONF" >"$new"
      [ -z "$(tail -c 1 "$TMUX_CONF")" ] || printf '\n' >>"$new"
      printf '\n%s\n%s\n' "$COMMENT" "$SOURCE_LINE" >>"$new"
    else
      printf '%s\n%s\n' "$COMMENT" "$SOURCE_LINE" >"$new"
    fi
    if [ $dry = 1 ]; then
      if [ -f "$TMUX_CONF" ]; then diff -u "$TMUX_CONF" "$new" || true; else diff -u /dev/null "$new" || true; fi
    else
      backup "$TMUX_CONF"
      replace "$TMUX_CONF" "$new"
      say "  added"
    fi
  fi

  if tmux_running; then
    # Only our own file: re-sourcing the user's whole config can have side
    # effects (or errors) that have nothing to do with surikat.
    run tmux source-file "$CONF"
    say "  loaded into the running tmux server"
  fi
}

uninstall_tmux_conf() {
  say "tmux"
  if tmux_running && [ -n "$(tmux show -gv @surikat_pane_icon 2>/dev/null)" ]; then
    run "$REPO/bin/surikat-tmux" --remove
    say "  removed formats and key bindings from the running server"
  fi

  if [ -f "$TMUX_CONF" ] && grep -qxF "$SOURCE_LINE" "$TMUX_CONF"; then
    local content suffix new=$TMPD/tmux.conf
    content=$(
      cat "$TMUX_CONF"
      printf x
    )
    content=${content%x}
    suffix=$'\n'"$COMMENT"$'\n'"$SOURCE_LINE"$'\n'
    if [ "$content" = "$COMMENT"$'\n'"$SOURCE_LINE"$'\n' ]; then
      : >"$new"
    elif [[ $content == *"$suffix" ]]; then
      printf '%s' "${content%"$suffix"}" >"$new"
    else
      # Moved or edited by hand: drop just our two lines.
      awk -v c="$COMMENT" -v s="$SOURCE_LINE" '$0 != c && $0 != s' "$TMUX_CONF" >"$new"
    fi
    if [ $dry = 1 ]; then
      diff -u "$TMUX_CONF" "$new" || true
    else
      backup "$TMUX_CONF"
      if [ -s "$new" ]; then
        replace "$TMUX_CONF" "$new"
      else
        rm -f "$TMUX_CONF"
      fi
      say "  removed the source line from $TMUX_CONF"
    fi
  fi

  if [ -L "$CONF" ] || { [ -f "$CONF" ] && grep -q surikat-tmux "$CONF"; }; then
    run rm -f "$CONF"
    say "  removed $CONF"
    [ $dry = 1 ] || rmdir "$CONF_DIR" 2>/dev/null || true
  fi
}

# --- Claude Code settings ------------------------------------------------------

# shellcheck disable=SC2016
JQ_STRIP='
def strip:
  if (.hooks | type) != "object" then . else
    .hooks |= with_entries(
      .value |= ((if type == "array" then . else [] end)
        | map(if (.hooks | type) == "array"
              then .hooks |= map(select(((.command // "") | tostring | test("surikat-hook")) | not))
              else . end)
        | map(select((.hooks | type) != "array" or (.hooks | length) > 0))))
    | .hooks |= with_entries(select(.value | length > 0))
    | if .hooks == {} then del(.hooks) else . end
  end;'

# shellcheck disable=SC2016
JQ_ADD='
strip
| .hooks = (reduce $ev[] as $e (.hooks // {};
    .[$e[0]] = ((.[$e[0]] // []) + [{hooks: [{type: "command", command: ($cmd + " " + $e[1]), timeout: 10}]}])))'

merge_settings() {
  local action=$1 new=$TMPD/settings.json orig=$TMPD/settings.orig
  say "hooks -> $CLAUDE_SETTINGS"
  if [ -f "$CLAUDE_SETTINGS" ]; then
    jq -e . "$CLAUDE_SETTINGS" >/dev/null 2>&1 ||
      die "$CLAUDE_SETTINGS is not valid JSON; fix it first, nothing was changed"
    cp "$CLAUDE_SETTINGS" "$orig"
  else
    [ "$action" = add ] || {
      say "  nothing to do"
      return 0
    }
    echo '{}' >"$orig"
  fi

  if [ "$action" = add ]; then
    jq --argjson ev "$EVENTS" --arg cmd "$HOOK_CMD" "$JQ_STRIP$JQ_ADD" "$orig" >"$new"
  else
    jq "$JQ_STRIP strip" "$orig" >"$new"
  fi

  if [ -f "$CLAUDE_SETTINGS" ] && [ "$(jq -S . "$orig")" = "$(jq -S . "$new")" ]; then
    say "  up to date"
    return 0
  fi
  if [ $dry = 1 ]; then
    diff -u "$orig" "$new" || true
    return 0
  fi
  if [ -f "$CLAUDE_SETTINGS" ]; then
    backup "$CLAUDE_SETTINGS"
  else
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  fi
  replace "$CLAUDE_SETTINGS" "$new"
  say "  updated"
}

# --- state -------------------------------------------------------------------

remove_state() {
  case $STATE_DIR in
    "" | / | "$HOME" | "$HOME/") die "refusing to remove state dir '$STATE_DIR'" ;;
  esac
  if [ -d "$STATE_DIR" ]; then
    run rm -rf "$STATE_DIR"
    say "state: removed $STATE_DIR"
    [ $dry = 1 ] || rmdir "$(dirname "$STATE_DIR")" 2>/dev/null || true
  fi
}

# --- main --------------------------------------------------------------------

[ $dry = 1 ] && say "dry run: nothing will be written"
if [ $mode = install ]; then
  check_requirements
  install_scripts
  merge_settings add
  install_tmux_conf
  say ""
  say "done. Running Claude sessions pick up the hooks with their next event."
  say "Keys: prefix C dashboard · prefix N next waiting · prefix P back · prefix T tree"
else
  uninstall_tmux_conf
  merge_settings strip
  uninstall_scripts
  remove_state
  say ""
  say "uninstalled. Backups (*.bak.*) were kept."
fi
