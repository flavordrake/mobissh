#!/usr/bin/env bash
# scripts/capture-tmux-cc.sh — capture a REAL tmux -CC control-mode protocol
# sample from a THROWAWAY session (never the owner's live `main` session), for
# use as a parser test fixture + validation-spike ground truth (#907 / epic #906).
#
# It creates an isolated tmux server (private socket), builds a session with two
# windows, attaches a control-mode client that drives some output + a layout
# change, then captures both:
#   1) the raw -CC protocol stream (the fixture the parser consumes), and
#   2) tmux's INDEPENDENT truth (list-windows -F), so the validation spike can
#      assert parser-view == tmux-truth.
#
# Usage: scripts/capture-tmux-cc.sh [OUT_DIR]
#   OUT_DIR defaults to native/test/fixtures/tmux_cc
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-${REPO_ROOT}/native/test/fixtures/tmux_cc}"
mkdir -p "$OUT_DIR"

# Private throwaway server: a dedicated socket name so we NEVER touch the
# owner's default tmux server / `main` session.
SOCK="mobissh-cc-capture-$$"
TM() { tmux -L "$SOCK" "$@"; }

cleanup() { TM kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT

STREAM="${OUT_DIR}/capture.cc"
TRUTH_WINDOWS="${OUT_DIR}/truth-windows.txt"

# 1) Build the throwaway session OUTSIDE control mode (so the -CC client we
#    attach next sees a clean startup_block listing the existing state).
TM new-session -d -s cc -x 80 -y 24 -n win0
TM new-window -t cc -n win1
TM select-window -t cc:win0

# 3) Attach a control-mode client UNDER A PTY and observe its notifications while
#    a SEPARATE out-of-band normal tmux client drives the server. `tmux -CC
#    attach` calls tcgetattr on its tty, so it must run under a pty (`script`)
#    with stdin == that pty (NOT a pipe). We therefore can't feed it commands on
#    stdin; instead the -CC client just sits attached and PUSHES %notifications
#    while we mutate the server from outside with plain `tmux` commands.
#
#    The -CC client runs in the background writing the protocol to $STREAM via
#    `script`'s typescript file (letting script own the fd keeps the pty intact).
script -q -c "tmux -L $SOCK -CC attach -t cc" "$STREAM" &
SCRIPT_PID=$!
sleep 0.6  # let the startup_block (%begin … %end) land

# Drive the server out-of-band. Each mutation pushes a %notification to the
# attached -CC client.
TM send-keys -t cc:win0 'echo hello-cc' Enter
sleep 0.4
TM split-window -t cc:win0 -h           # -> %layout-change
sleep 0.4
TM send-keys -t cc:win0 'printf back' Enter
sleep 0.4
TM select-window -t cc:win1             # -> %session-window-changed
sleep 0.4
TM select-window -t cc:win0
sleep 0.4
# Capture the new window's id so the later kill targets it regardless of rename.
NEWWIN_ID="$(TM new-window -P -F '#{window_id}' -t cc -n win2)"  # -> %window-add
sleep 0.4
TM rename-window -t "cc:$NEWWIN_ID" renamed   # -> %window-renamed
sleep 0.4
TM kill-window -t "$NEWWIN_ID"                 # -> %window-close
sleep 0.4

# 4) Capture tmux's INDEPENDENT truth (the parity ground-truth for the spike) at
#    the SAME final state the -CC client has been told about: win0 active, win1
#    present, win0 split into two panes. This is what the parser's accumulated
#    view must equal.
TM list-windows -t cc -F '#{window_index} #{window_name} #{window_active} #{window_width}x#{window_height} #{window_layout}' \
  > "$TRUTH_WINDOWS"

# Tear down the -CC client cleanly (%exit + ST), then the server.
TM detach-client -s cc 2>/dev/null || true
sleep 0.3
TM kill-server 2>/dev/null || true
wait "$SCRIPT_PID" 2>/dev/null || true

# Drop `script`'s banner lines + the carriage returns the pty injects.
sed -i -e '/^Script started/d' -e '/^Script done/d' -e 's/\r$//' "$STREAM"

echo "+ captured -CC stream -> $STREAM"
echo "+ truth windows       -> $TRUTH_WINDOWS"
wc -l "$STREAM" "$TRUTH_WINDOWS"
