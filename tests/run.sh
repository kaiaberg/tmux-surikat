#!/usr/bin/env bash
# tests/run.sh: automated tests on a private tmux server with temp state.
# Never touches the real state dir or the user's tmux server (L7, L8).
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
BIN=$REPO/bin
REAL_TMUX=$(command -v tmux) || {
  echo "tmux not found"
  exit 1
}
command -v jq >/dev/null || {
  echo "jq not found"
  exit 1
}

# Short path: macOS limits unix socket paths to 104 bytes.
T=$(mktemp -d /tmp/skt.XXXXXX)
export TMUX_TMPDIR=$T SURIKAT_DIR=$T/state HOME=$T/home
mkdir -p "$T/shim" "$HOME"
cat >"$T/shim/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L test -f /dev/null "\$@"
EOF
chmod +x "$T/shim/tmux"
export PATH="$T/shim:$PATH"
unset TMUX TMUX_PANE XDG_STATE_HOME SURIKAT_STALE_HOURS COLUMNS

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
eq() {
  [ "$1" = "$2" ] && return 0
  echo "     expected: '$2'"
  echo "     got:      '$1'"
  return 1
}
lt() {
  [ "$1" -lt "$2" ] && return 0
  echo "     $1 is not below $2"
  return 1
}

# hook EVENT PANE JSON
hook() { printf '%s' "$3" | TMUX_PANE=$2 "$BIN/surikat-hook" "$1"; }
# js SID 'jq object': hook JSON with that session_id
js() {
  local extra=${2:-}
  [ -n "$extra" ] || extra='{}'
  # shellcheck disable=SC2016
  jq -nc --arg sid "$1" '{session_id: $sid, cwd: ("/work/proj-" + $sid)} + '"$extra"
}
rec() { cat "$SURIKAT_DIR/$1.json" 2>/dev/null; }
field() { jq -r ".$2 // \"\"" "$SURIKAT_DIR/$1.json" 2>/dev/null; }
popt() { tmux display -p -t "$1" '#{@surikat}'; }
setf() { # setf SID 'jq update'
  jq -c "$2" "$SURIKAT_DIR/$1.json" >"$T/tmp.json" && mv "$T/tmp.json" "$SURIKAT_DIR/$1.json"
}
cur() { tmux display -p '#{pane_id}'; }
ms() { # ms CMD...: wall time in milliseconds
  local TIMEFORMAT=%3R t
  t=$({ time "$@" >/dev/null 2>&1; } 2>&1)
  awk -v t="$t" 'BEGIN { printf "%d", t * 1000 }'
}
reset_state() {
  rm -rf "$SURIKAT_DIR"
  mkdir -p "$SURIKAT_DIR"
}

tmux new-session -d -s main -x 220 -y 50
P1=$(tmux display -p -t main '#{pane_id}')
P2=$(tmux split-window -P -F '#{pane_id}' -t main)
P3=$(tmux new-window -P -F '#{pane_id}' -t main)
P4=$(tmux new-window -P -F '#{pane_id}' -t main)
"$BIN/surikat-tmux"

echo "--- state transitions"
reset_state
hook start "$P1" "$(js s1 '{source: "startup"}')"
check "start -> ready" eq "$(field s1 state)" ready
check "pane option set" eq "$(popt "$P1")" ready
check "project from cwd" eq "$(field s1 project)" proj-s1
hook prompt "$P1" "$(js s1 '{prompt: "fix\nthe bug"}')"
check "prompt -> running" eq "$(field s1 state)" running
check "prompt stored, newlines collapsed" eq "$(field s1 prompt)" "fix the bug"
hook perm "$P1" "$(js s1 '{tool_name: "Bash", tool_input: {command: "rm -rf build"}}')"
check "permission request -> perm" eq "$(field s1 state)" perm
check "perm message" eq "$(field s1 message)" "Bash: rm -rf build"
check "pane option perm" eq "$(popt "$P1")" perm
setf s1 '.since = 100'
hook perm "$P1" "$(js s1 '{tool_name: "Bash", tool_input: {command: "rm -rf build"}}')"
check "since stable while the state is unchanged" eq "$(field s1 since)" 100
hook notify "$P1" "$(js s1 '{notification_type: "permission_prompt", message: "Claude needs your permission to use Bash"}')"
check "perm message kept across the notification" eq "$(field s1 message)" "Bash: rm -rf build"
hook tool "$P1" "$(js s1 '{agent_id: "sub1", tool_name: "Read", tool_input: {file_path: "/x"}}')"
check "subagent tool keeps perm" eq "$(field s1 state)" perm
hook tool "$P1" "$(js s1 '{tool_name: "Bash", tool_input: {command: "rm -rf build"}}')"
check "approved tool -> running" eq "$(field s1 state)" running
check "pending cleared" eq "$(field s1 pending)" ""
hook stop "$P1" "$(js s1 '{last_assistant_message: "All done."}')"
check "stop -> done" eq "$(field s1 state)" 'done'
check "done message" eq "$(field s1 message)" "All done."
hook notify "$P1" "$(js s1 '{notification_type: "idle_prompt", message: "Claude is waiting for your input"}')"
check "idle after done ignored" eq "$(field s1 state)" 'done'
hook prompt "$P1" "$(js s1 '{prompt: "next"}')"
hook notify "$P1" "$(js s1 '{notification_type: "idle_prompt", message: "Claude is waiting for your input"}')"
check "idle after an interrupt" eq "$(field s1 state)" idle
hook notify "$P1" "$(js s1 '{message: "Claude needs your permission to use Write"}')"
check "untyped permission message -> perm" eq "$(field s1 state)" perm
hook prompt "$P1" "$(js s1 '{prompt: "again"}')"
hook notify "$P1" "$(js s1 '{message: "Something happened"}')"
check "untyped other message -> idle" eq "$(field s1 state)" idle
hook prompt "$P1" "$(js s1 '{prompt: "again"}')"
hook notify "$P1" "$(js s1 '{notification_type: "auth_success", message: "ok"}')"
check "unrelated notification ignored" eq "$(field s1 state)" running
hook fail "$P1" "$(js s1 '{error: "rate_limit"}')"
check "StopFailure -> idle" eq "$(field s1 state)" idle
check "StopFailure message" eq "$(field s1 message)" rate_limit
hook stop "$P1" "$(js s1 '{last_assistant_message: "ok"}')"
hook start "$P1" "$(js s1 '{source: "compact"}')"
check "compaction keeps the state" eq "$(field s1 state)" 'done'
hook start "$P1" "$(js s1 '{source: "resume"}')"
check "resume -> ready" eq "$(field s1 state)" ready
hook end "$P1" "$(js s1 '{reason: "exit"}')"
check "end removes the record" test ! -e "$SURIKAT_DIR/s1.json"
check "end unsets the pane option" eq "$(popt "$P1")" ""

echo "--- robustness"
reset_state
printf '{ not json' | TMUX_PANE=$P1 "$BIN/surikat-hook" start
check "malformed JSON: exit 0" test $? -eq 0
printf '' | TMUX_PANE=$P1 "$BIN/surikat-hook" start
check "empty stdin: exit 0" test $? -eq 0
hook start "$P1" '{"session_id":"../evil","cwd":"/x"}'
check "path-traversal session id: exit 0" test $? -eq 0
hook start "$P1" '{"session_id":"x/y","cwd":"/x"}'
hook bogus "$P1" "$(js s9)"
check "unknown event: exit 0" test $? -eq 0
check "no files written by bad input" eq "$(ls -A "$SURIKAT_DIR")" ""
check "nothing escaped the state dir" test ! -e "$T/evil.json"
hook tool "$P1" '{"tool_input":{"content":"\"session_id\": \"decoy\""},"session_id":"real"}'
check "nested session_id can't redirect the write" test ! -e "$SURIKAT_DIR/decoy.json"
hook start "" "$(js out1)"
check "outside tmux: record written" eq "$(field out1 state)" ready
check "outside tmux: no pane" eq "$(field out1 pane)" ""
two() {
  hook perm "$P2" "$(js t1 '{tool_name: "Bash", tool_input: {command: "ls"}}')"
  hook stop "$P2" "$(js t1)"
}
check "two transitions under 300ms" lt "$(ms two)" 300
hot() { hook tool "$P2" "$(js t1 '{tool_name: "Bash", tool_input: {command: "ls"}}')"; }
hook prompt "$P2" "$(js t1)"
check "running -> running no-op under 100ms" lt "$(ms hot)" 100
echo '{ broken' >"$SURIKAT_DIR/c1.json"
hook start "$P2" "$(js c1)"
check "corrupt record is replaced" eq "$(field c1 state)" ready
if command -v perl >/dev/null; then
  J=$(js pidtest) H=$BIN/surikat-hook
  export J H
  ppid=$(perl -e 'print "$$\n"; system("sh", "-c", q{printf "%s" "$J" | "$H" start; :})')
  check "Claude PID found through an sh -c parent" eq "$(field pidtest pid)" "$ppid"
fi

echo "--- questions"
reset_state
hook perm "$P1" "$(js q1 '{tool_name: "AskUserQuestion", tool_input: {questions: [{question: "Which DB?"}, {question: "Deploy now?"}]}}')"
check "AskUserQuestion -> ask" eq "$(field q1 state)" ask
check "question texts joined" eq "$(field q1 message)" "Which DB? / Deploy now?"
hook notify "$P1" "$(js q1 '{notification_type: "permission_prompt", message: "Claude needs your permission"}')"
check "permission notification keeps ask" eq "$(field q1 state)" ask
hook tool "$P1" "$(js q1 '{tool_name: "Bash", tool_input: {command: "ls"}}')"
check "answered -> running" eq "$(field q1 state)" running

echo "--- tmux"
reset_state
hook perm "$P1" "$(js w1 '{tool_name: "Bash", tool_input: {command: "x"}}')"
hook stop "$P2" "$(js w2)"
check "two Claude panes in one window show both icons" eq "$(tmux display -p -t "$P1" '#{E:@surikat_window_icons}')" "#[fg=red]●#[default] #[fg=green]✓#[default] "
hook prompt "$P2" "$(js w2)"
check "dim ring for running" eq "$(tmux display -p -t "$P1" '#{E:@surikat_window_icons}')" "#[fg=red]●#[default] #[dim]◌#[default] "
check "icons prepended to window-status-format" eq "$(tmux show -gv window-status-format | cut -c1-26)" '#{E:@surikat_window_icons}'
"$BIN/surikat-tmux"
"$BIN/surikat-tmux"
n=$(tmux show -gv window-status-current-format | grep -o 'surikat_window_icons' | wc -l | tr -d ' ')
check "re-applying doesn't duplicate icons" eq "$n" 1
n=$(tmux show -gv status-right | grep -o 'surikat --count' | wc -l | tr -d ' ')
check "re-applying doesn't duplicate the summary" eq "$n" 1
check "status-right-length raised" eq "$(tmux show -gv status-right-length)" 80
tmux set -p -t "$P1" @surikat_mark fav
"$BIN/surikat-tmux" --remove
check "--remove restores window-status-format" eq "$(tmux show -gv window-status-format)" "$("$REAL_TMUX" -L test-pristine -f /dev/null start-server \; show -gv window-status-format \; kill-server 2>/dev/null)"
check "--remove restores status-right-length" eq "$(tmux show -gv status-right-length)" 40
check "--remove unsets pane options" eq "$(popt "$P1")" ""
check "--remove unsets marks" eq "$(tmux display -p -t "$P1" '#{@surikat_mark}')" ""
"$BIN/surikat-tmux"

echo "--- surikat"
reset_state
hook stop "$P3" "$(js d1 '{last_assistant_message: "finished"}')"
hook perm "$P1" "$(js p1 '{tool_name: "Bash", tool_input: {command: "a"}}')"
hook perm "$P2" "$(js p2 '{tool_name: "Bash", tool_input: {command: "b"}}')"
hook prompt "$P4" "$(js r1 '{prompt: "working on it"}')"
hook start "" "$(js n1)"
setf p1 '.since = 1000'
setf p2 '.since = 2000'
setf d1 '.since = 500'
check "--count with tmux styles" eq "$("$BIN/surikat" --count)" "#[fg=red]●2#[default] #[fg=green]✓1#[default]"
order=$("$BIN/surikat" --list | awk '{print $1}' | tr '\n' ' ')
check "sorted by priority" eq "$order" "● ● ✓ ◌ ○ "
first=$("$BIN/surikat" --rows | head -n 1 | cut -f1)
check "shortest wait first within a state by default" eq "$first" "$P2"
first=$(SURIKAT_ORDER=desc "$BIN/surikat" --rows | head -n 1 | cut -f1)
check "SURIKAT_ORDER=desc: longest wait first" eq "$first" "$P1"
tmux set -g @surikat_order desc
first=$("$BIN/surikat" --rows | head -n 1 | cut -f1)
check "@surikat_order desc: longest wait first" eq "$first" "$P1"
tmux set -gu @surikat_order
check "message falls back to the prompt" sh -c "'$BIN/surikat' --list | grep -q 'working on it'"

echo "--- theme"
check "age: dim when fresh" sh -c "'$BIN/surikat' --rows | grep -q \"^$P3	  $(printf '\033')\\[32m✓$(printf '\033')\\[0m $(printf '\033')\\[1;31m\""
setf d1 ".since = $(($(date +%s) - 10))"
check "age: bold red after an hour, dim when fresh" sh -c "'$BIN/surikat' --rows | grep \"^$P3	\" | grep -q \"$(printf '\033')\\[2m1[01]s\""
setf d1 '.since = 500'
check "--list without a tty has no escapes" sh -c "! '$BIN/surikat' --list | grep -q \"$(printf '\033')\""
check "emoji style" eq "$(SURIKAT_STYLE=emoji "$BIN/surikat" --list | awk '{print $1}' | tr '\n' ' ')" "🔴 🔴 🟢 ⚙ ⚪ "
check "emoji style: --count without styles" eq "$(SURIKAT_STYLE=emoji "$BIN/surikat" --count)" "🔴2 🟢1"
check "nerd style" eq "$(SURIKAT_STYLE=nerd "$BIN/surikat" --list | head -n 1 | awk '{print $1}')" "$(printf '\357\200\243')"
tmux set -g @surikat_color_perm 'fg=colour208,bold'
check "color override as a tmux style" eq "$("$BIN/surikat" --count)" "#[fg=colour208,bold]●2#[default] #[fg=green]✓1#[default]"
check "color override in ANSI" sh -c "'$BIN/surikat' --rows | head -n 1 | grep -q \"$(printf '\033')\\[38;5;208;1m●\""
tmux set -g @surikat_color_perm '#ff8000'
check "hex colors in ANSI" sh -c "'$BIN/surikat' --header /nonexistent | head -n 1 | grep -q \"$(printf '\033')\\[38;2;255;128;0m●\""
"$BIN/surikat-tmux"
tmux set -g @surikat_color_perm 'fg=red,bold'
"$BIN/surikat-tmux"
check "re-applying picks up a new style, commas escaped" eq "$(tmux display -p -t "$P1" '#{E:@surikat_pane_icon}')" "#[fg=red,bold]●#[default] "
tmux set -gu @surikat_color_perm
tmux set -g @surikat_style emoji
"$BIN/surikat-tmux"
check "@surikat_style emoji in the status bar" eq "$(tmux display -p -t "$P1" '#{E:@surikat_pane_icon}')" "🔴 "
tmux set -gu @surikat_style
"$BIN/surikat-tmux"

echo "--- marks"
mopt() { tmux display -p -t "$1" '#{@surikat_mark}'; }
panes() { "$BIN/surikat" --rows "$@" | cut -f1 | tr '\n' ' '; }
"$BIN/surikat" --fav "$P1"
check "--fav sets the pane option" eq "$(mopt "$P1")" fav
check "favorite first within a state" eq "$(panes)" "$P1 $P2 $P3 $P4 "
check "favorite shows a star" sh -c "'$BIN/surikat' --list | head -n 1 | grep -q '^★ ●'"
"$BIN/surikat" --fav "$P3"
check "favorite doesn't beat urgency" eq "$(panes)" "$P1 $P2 $P3 $P4 "
"$BIN/surikat" --fav "$P1"
check "--fav again clears the mark" eq "$(mopt "$P1")" ""
"$BIN/surikat" --fav "$P3"
"$BIN/surikat" --side "$P2"
check "--side sets the pane option" eq "$(mopt "$P2")" side
check "sidelined last within a state" eq "$(panes)" "$P1 $P2 $P3 $P4 "
e=$(printf '\033')
check "sidelined rows are dimmed" sh -c "'$BIN/surikat' --rows | grep -q \"^$P2	$e\\[2m$e\\[2m↓$e\\[0m$e\\[2m \""
check "sidelined panes aren't counted" eq "$("$BIN/surikat" --count)" "#[fg=red]●1#[default] #[fg=green]✓1#[default]"
check "tree pane icon with mark" eq "$(tmux display -p -t "$P2" '#{E:@surikat_tree_pane_icon}')" "#[dim]↓#[default]#[fg=red]●#[default] "
"$BIN/surikat" --fav "$P1"
check "tree window icons with marks" eq "$(tmux display -p -t "$P1" '#{E:@surikat_tree_window_icons}')" "#[fg=yellow]★#[default]#[fg=red]●#[default] #[dim]↓#[default]#[fg=red]●#[default] "
check "status bar icons without marks" eq "$(tmux display -p -t "$P1" '#{E:@surikat_window_icons}')" "#[fg=red]●#[default] #[fg=red]●#[default] "
"$BIN/surikat" --fav "$P2"
check "--fav replaces sidelined" eq "$(mopt "$P2")" fav
"$BIN/surikat" --fav "$P1"
"$BIN/surikat" --fav "$P2"
st=$T/order
echo desc >"$st"
check "--rows --state follows the state file" eq "$(panes --state "$st")" "$P1 $P2 $P3 $P4 "
"$BIN/surikat" --fav "$P2"
check "--rows --state desc keeps favorites first" eq "$(panes --state "$st" | cut -d' ' -f1)" "$P2"
"$BIN/surikat" --flip "$st"
check "--flip toggles the order" eq "$(cat "$st")" asc
check "--header names the order" sh -c "'$BIN/surikat' --header '$st' | grep -q 'shortest wait first'"
tmux select-window -t "$P4"
tmux select-pane -t "$P4"
"$BIN/surikat" --side
check "--side without a pane marks the current one" eq "$(mopt "$P4")" side
"$BIN/surikat" --side
"$BIN/surikat" --side "$P2"
tmux select-pane -t "$P3"
"$BIN/surikat" --next
check "--next skips sidelined sessions" eq "$(cur)" "$P1"
"$BIN/surikat" --next
check "--next: favorite before the rest of its state" eq "$(cur)" "$P3"
rm -f "$SURIKAT_DIR"/.trail-*
for p in "$P1" "$P2" "$P3" "$P4"; do tmux set -pu -t "$p" @surikat_mark; done

tmux select-window -t "$P4"
tmux select-pane -t "$P4"
start=$(cur)
"$BIN/surikat" --next
check "--next jumps to the oldest perm" eq "$(cur)" "$P1"
"$BIN/surikat" --next
check "--next cycles to the next perm" eq "$(cur)" "$P2"
"$BIN/surikat" --next
check "--next visits done after perm" eq "$(cur)" "$P3"
"$BIN/surikat" --next
check "--next wraps around" eq "$(cur)" "$P1"
"$BIN/surikat" --back
check "--back: one step" eq "$(cur)" "$P3"
"$BIN/surikat" --back
"$BIN/surikat" --back
"$BIN/surikat" --back
check "--back retraces to the start" eq "$(cur)" "$start"
"$BIN/surikat" --back
check "--back stays put on an empty trail" eq "$(cur)" "$start"

"$BIN/surikat" --next
"$BIN/surikat" --next
"$BIN/surikat" --next # trail: P4 P1 P2; now at P3
P5=$(tmux split-window -P -F '#{pane_id}' -t "$P2")
tmux kill-pane -t "$P2"
"$BIN/surikat" --back
check "--back skips killed panes" eq "$(cur)" "$P1"

"$BIN/surikat" --seen "$P3"
check "--seen: done -> ready" eq "$(field d1 state)" ready
check "--seen sets the pane option" eq "$(popt "$P3")" ready
"$BIN/surikat" --seen "$P1"
check "--seen leaves perm alone" eq "$(field p1 state)" perm

reset_state
hook stop "$P5" "$(js k1)"
tmux kill-pane -t "$P5"
"$BIN/surikat" --gc
check "GC removes a killed pane's record" test ! -e "$SURIKAT_DIR/k1.json"
hook stop "$P1" "$(js o1)"
setf o1 '.socket = "/elsewhere/tmux-1/default" | .pane = "%999"'
"$BIN/surikat" --gc
check "GC keeps records of another tmux server" test -e "$SURIKAT_DIR/o1.json"
hook prompt "$P1" "$(js st1)"
hook stop "$P1" "$(js st2)"
setf st1 '.ts = 1000'
setf st2 '.ts = 1000'
"$BIN/surikat" --gc
check "GC removes a stale running record" test ! -e "$SURIKAT_DIR/st1.json"
check "GC keeps an old done record" test -e "$SURIKAT_DIR/st2.json"
sleep 0 &
deadpid=$!
wait $deadpid
hook stop "$P1" "$(js dp)"
setf dp ".pid = $deadpid"
"$BIN/surikat" --gc
check "GC removes a dead-PID record" test ! -e "$SURIKAT_DIR/dp.json"
touch "$SURIKAT_DIR/x.json.tmp.1"
touch -t 202001010000 "$SURIKAT_DIR/y.json.tmp.2"
"$BIN/surikat" --gc
check "GC removes old temp files" test ! -e "$SURIKAT_DIR/y.json.tmp.2"
check "GC keeps fresh temp files" test -e "$SURIKAT_DIR/x.json.tmp.1"

reset_state
i=0
while [ $i -lt 30 ]; do
  hook stop "$P1" "$(js "many$i")"
  i=$((i + 1))
done
check "--count with 30 records under 150ms" lt "$(ms "$BIN/surikat" --count)" 150
reset_state
check "empty dir: --count prints nothing" eq "$("$BIN/surikat" --count)" ""
check "empty dir: --list prints nothing" eq "$("$BIN/surikat" --list)" ""
rm -rf "$SURIKAT_DIR"
check "missing dir: --count prints nothing" eq "$("$BIN/surikat" --count)" ""

echo "--- shells"
reset_state
hook stop "$P1" "$(js sh1 '{last_assistant_message: "ok"}')"
for sh in sh bash zsh fish; do
  command -v $sh >/dev/null || continue
  # The picker's fzf commands are run by $SHELL; they must work in any shell.
  out=$($sh -c "'$BIN/surikat' --rows" 2>&1 | cut -f1)
  check "fzf reload command works in $sh" eq "$out" "$P1"
  out=$($sh -c "'$BIN/surikat' --preview '$P1'" 2>&1 | head -n 1)
  check "fzf preview command works in $sh" eq "$out" "proj-sh1  /work/proj-sh1"
done

if command -v fzf >/dev/null; then
  echo "--- picker (fzf $(fzf --version | cut -d' ' -f1))"
  FZF_V=$(fzf --version | awk '{ split($1, v, "."); print v[1] * 1000000 + v[2] * 1000 + v[3] }')
  # wait_for PANE TEXT: poll the pane until TEXT shows up (max ~5s).
  wait_for() {
    local i=0
    while [ $i -lt 50 ]; do
      tmux capture-pane -p -t "$1" 2>/dev/null | grep -qF "$2" && return 0
      sleep 0.1
      i=$((i + 1))
    done
    tmux capture-pane -p -t "$1" 2>/dev/null | sed 's/^/     | /'
    return 1
  }
  # wait_re PANE REGEX: like wait_for, with an extended regex.
  wait_re() {
    local i=0
    while [ $i -lt 50 ]; do
      tmux capture-pane -p -t "$1" 2>/dev/null | grep -qE "$2" && return 0
      sleep 0.1
      i=$((i + 1))
    done
    return 1
  }
  # open_picker: run the dashboard in a new window, print its pane id.
  open_picker() {
    tmux new-window -P -F '#{pane_id}' -t main \
      "env SURIKAT_DIR='$SURIKAT_DIR' PATH='$PATH' '$BIN/surikat'"
  }
  reset_state
  hook perm "$P1" "$(js f1 '{tool_name: "Bash", tool_input: {command: "make deploy"}}')"
  hook stop "$P3" "$(js f2 '{last_assistant_message: "tests pass"}')"
  setf f1 '.since = 1000'
  PK=$(open_picker)
  check "picker shows the legend" wait_for "$PK" "needs permission"
  check "picker lists sessions" wait_for "$PK" "make deploy"
  check "picker previews the pane" wait_for "$PK" "prompt:"
  tmux send-keys -t "$PK" Enter
  i=0
  while [ "$(cur)" != "$P1" ] && [ $i -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  check "enter jumps to the selected session" eq "$(cur)" "$P1"
  check "enter records the trail" test -s "$SURIKAT_DIR/.trail-noclient"
  PK=$(open_picker)
  wait_for "$PK" "tests pass" >/dev/null
  tmux send-keys -t "$PK" Down C-x
  i=0
  while [ "$(field f2 state)" != ready ] && [ $i -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  check "ctrl-x marks the session as seen" eq "$(field f2 state)" ready
  check "ctrl-x leaves the picker open" wait_for "$PK" "ready/seen"
  wait_re "$PK" '○ +[0-9]+s +main' >/dev/null # the reload is done
  tmux send-keys -t "$PK" Down C-f # bottom row: Down wraps to the top
  i=0
  while [ "$(tmux display -p -t "$P1" '#{@surikat_mark}')" != fav ] && [ $i -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  check "selection is cyclic; ctrl-f marks a favorite" eq "$(tmux display -p -t "$P1" '#{@surikat_mark}')" fav
  check "favorite shows a star in the picker" wait_for "$PK" "★ ●"
  if [ "$FZF_V" -ge 40000 ]; then
    check "picker header shows the default order" wait_for "$PK" "shortest wait first"
    tmux send-keys -t "$PK" C-o
    check "ctrl-o toggles the order" wait_for "$PK" "longest wait first"
  else
    # fzf < 0.40 can't update the header (covered by the shim tests below).
    tmux send-keys -t "$PK" C-o
  fi
  # The header changes before the reload; keys sent during a reload are
  # undone when --track restores the cursor, so let it finish.
  sleep 0.5
  tmux send-keys -t "$PK" Up C-l # top row: Up wraps to the bottom
  i=0
  while [ "$(tmux display -p -t "$P3" '#{@surikat_mark}')" != side ] && [ $i -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  check "ctrl-l sidelines a session" eq "$(tmux display -p -t "$P3" '#{@surikat_mark}')" side
  tmux set -pu -t "$P1" @surikat_mark
  tmux set -pu -t "$P3" @surikat_mark
  tmux send-keys -t "$PK" Escape
  i=0
  while pane_alive=$(tmux display -p -t "$PK" '#{pane_id}' 2>/dev/null) &&
    [ "$pane_alive" = "$PK" ] && [ $i -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  check "esc closes the picker" test "$(tmux display -p -t "$PK" '#{pane_id}' 2>/dev/null)" != "$PK"

  echo "--- picker with an older fzf (shim)"
  # A shim that claims an older version and, like a real old fzf, rejects
  # options that version doesn't know. Distros ship old fzf: Debian 12 has
  # 0.38, Ubuntu 24.04 0.44.
  REAL_FZF=$(command -v fzf)
  mkdir -p "$T/oldfzf"
  cat >"$T/oldfzf/fzf" <<EOF
#!/bin/sh
v=\$(cat "$T/oldfzf/version")
[ "\$1" = --version ] && { echo "\$v (shim)"; exit 0; }
for a in "\$@"; do
  case \$a in
    --track | --id-nth*) echo "unknown option: \$a" >&2; exit 2 ;;
    *transform-header*)
      [ "\$(echo "\$v" | cut -d. -f2)" -lt 40 ] && { echo "unknown action" >&2; exit 2; } ;;
  esac
done
exec "$REAL_FZF" "\$@"
EOF
  chmod +x "$T/oldfzf/fzf"
  # open_old VERSION: open the picker with the shim claiming VERSION.
  open_old() {
    echo "$1" >"$T/oldfzf/version"
    PATH="$T/oldfzf:$PATH" open_picker
  }
  close_picker() {
    tmux send-keys -t "$1" Escape
    tmux kill-pane -t "$1" 2>/dev/null
  }
  reset_state
  hook stop "$P1" "$(js o1 '{last_assistant_message: "old one"}')"
  hook stop "$P3" "$(js o2 '{last_assistant_message: "new one"}')"
  setf o1 '.since = 1000'
  PK=$(open_old 0.38.0)
  check "fzf 0.38: picker opens" wait_for "$PK" "needs permission"
  check "fzf 0.38: static ctrl-o hint" wait_for "$PK" "order (flip wait time)"
  # first_row: "old" or "new", whichever session is listed first.
  first_row() {
    tmux capture-pane -p -t "$PK" | grep -oE '(old|new) one' | head -n 1 | cut -d' ' -f1
  }
  wait_for "$PK" "old one" >/dev/null
  check "fzf 0.38: shortest wait first by default" eq "$(first_row)" new
  tmux send-keys -t "$PK" C-o
  i=0
  while [ "$(first_row)" != old ] && [ $i -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  check "fzf 0.38: ctrl-o flips the order" eq "$(first_row)" old
  close_picker "$PK"
  PK=$(open_old 0.44.1)
  check "fzf 0.44: picker opens" wait_for "$PK" "needs permission"
  check "fzf 0.44: header names the order" wait_for "$PK" "shortest wait first"
  tmux send-keys -t "$PK" C-o
  check "fzf 0.44: ctrl-o updates the header" wait_for "$PK" "longest wait first"
  close_picker "$PK"
  PK=$(open_old 0.28.0)
  check "fzf 0.28: says the version is too old" wait_for "$PK" "needs fzf 0.29 or newer"
  close_picker "$PK"
fi

echo
echo "$pass passed, $failed failed"
[ $failed = 0 ]
