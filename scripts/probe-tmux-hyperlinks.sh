#!/usr/bin/env bash
# Probe which TERM value makes tmux 3.4 enable the `hyperlinks` client feature.
#
# For each candidate TERM, start a throwaway tmux server, attach a real pty
# client (via `script`) carrying that TERM, and read back
# #{client_termfeatures}. Prints a table of TERM -> features and whether
# `hyperlinks` is present.
#
# Background: tmux only FORWARDS OSC-8 hyperlinks to clients whose
# terminal-features include `hyperlinks`. flterm advertises TERM=xterm-256color
# (no hyperlinks). We want a TERM the built-in default-features table maps to
# `hyperlinks` with no ~/.tmux.conf.
set -euo pipefail

PROBE_OUT_DIR="${PROBE_OUT_DIR:-/tmp/mobissh/tmux-probe}"
mkdir -p "$PROBE_OUT_DIR"
LOGFILE="$PROBE_OUT_DIR/probe.log"
exec > >(tee -a "$LOGFILE") 2>&1

SOCK="probe$$"

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
}
trap cleanup EXIT

# Candidates. xterm-256color is flterm's current value (baseline).
CANDIDATES=(
  "xterm-256color"
  "tmux-256color"
  "tmux"
  "xterm-ghostty"
  "iterm2"
  "iTerm2"
  "wezterm"
  "foot"
  "contour"
  "rxvt-unicode-256color"
  "vte-256color"
)

probe_one() {
  local term="$1"
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$SOCK" -f /dev/null new-session -d -s s -x 80 -y 24 2>/dev/null || {
    echo "$term -> SERVER_START_FAILED"
    return
  }
  # Attach a real pty client carrying $term in the background; it just holds
  # the attach open via a long-lived shell command. We query features from a
  # SEPARATE control command so display-message output isn't swallowed by the
  # attached client's screen.
  local capfile="$PROBE_OUT_DIR/cap-$term.txt"
  TERM="$term" script -qfc \
    "tmux -L $SOCK -f /dev/null attach -t s" /dev/null > "$capfile" 2>&1 &
  local spid=$!
  # Give the client time to attach and feature-detect.
  sleep 1.5
  local feats
  feats="$(tmux -L "$SOCK" list-clients -F '#{client_termfeatures}' 2>/dev/null | tail -1 || true)"
  # Tear down the backgrounded attach.
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  kill "$spid" 2>/dev/null || true
  wait "$spid" 2>/dev/null || true
  if [ -z "$feats" ]; then
    feats="(no client attached; see $capfile)"
  fi
  local has="NO"
  case ",$feats," in
    *,hyperlinks,*) has="YES" ;;
  esac
  printf '%-26s hyperlinks=%-3s  %s\n' "$term" "$has" "$feats"
}

echo "tmux version: $(tmux -V)"
echo "probe started $(date +%Y%m%dT%H%M%S%z)"
for t in "${CANDIDATES[@]}"; do
  probe_one "$t"
done
echo "probe done"
