#!/usr/bin/env bash
# fake-tui.sh — deterministic Claude-Code-like TUI painter for emulator tests.
#
# Reproduces the SCREEN SHAPES the real daily driver (Claude Code in tmux)
# produces, which plain `echo` fixtures never exercise and where every copy /
# paint bug has lived:
#   - box-drawing borders around a multi-line $-continuation command,
#   - bulleted text with FORCED 2-space margins (TUI layout, not soft-wrap),
#   - a long URL that hard-wraps at the terminal width,
#   - a stream of timestamped agent-output lines WITH INTERIOR SPACES
#     (builds scrollback while "live", like an agent narrating),
#   - a persistent prompt line at the end (process stays alive so tmux mouse
#     mode + alt screen remain engaged).
#
# All content is DETERMINISTIC (fixed strings, numbered lines) so tests can
# assert exact verbatim copies — including interior spaces (the +98 bug class).
#
# Usage: fake-tui [stream_lines] [interval_seconds] [hold_seconds]
#   defaults: 40 lines, 0.1s apart, hold 600s (0 = exit to the prompt so the
#   test can run more commands in the same session).
set -u

LINES_N="${1:-40}"
INTERVAL="${2:-0.1}"
HOLD="${3:-600}"

# ANSI clear+home (alpine has no ncurses `clear`).
printf '\033[2J\033[H'
printf '╭──────────────────────────────────────────────╮\n'
printf '│ One-liner for the box (run in each shell):   │\n'
printf '│                                              │\n'
printf '│  $ curl -fsSL https://gist.example.com/mf/ \\ │\n'
printf '│      3c7ad5d8e4f7/raw/setup.sh | bash -s go  │\n'
printf '╰──────────────────────────────────────────────╯\n'
printf '\n'
printf '  Key points from the brief:\n'
printf '  - the bearer is reader-only so exposure stays\n'
printf '    low risk on the public gist\n'
printf '  - enrollment mints a writer JWT and pulls the\n'
printf '    dotfiles from the hub\n'
printf '\n'
printf '  Docs: https://docs.example.com/agent-hub/enrollment/getting-started#writer-jwt-mint\n'
printf '\n'

i=1
while [ "$i" -le "$LINES_N" ]; do
  printf 'TUI_%03d alpha beta gamma delta\n' "$i"
  i=$((i + 1))
  sleep "$INTERVAL"
done

printf 'TUI_DONE ready for input\n'
printf '> '
# Stay alive so the alt screen / mouse mode persist while the test drives
# scroll + copy (hold=0 exits to the prompt instead).
if [ "$HOLD" -gt 0 ]; then
  sleep "$HOLD"
fi
