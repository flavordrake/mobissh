#!/usr/bin/env bash
# scripts/process-cleanup.sh — reclaim the process table after long agent sessions.
#
# Long orchestration days leak: Dart analysis servers (one per agent flutter run),
# Gradle daemons, headless Chrome from web tests, `tail -f` watchers on finished
# task outputs, and orphaned script pipelines (bash+tee+sort reparented to PID 1).
# Enough of them and the kernel refuses new threads (errno=11) and even `gh` dies.
#
# SAFE-LIST (never touched): the emulator (qemu/emulator binaries), adb server,
# socat bridges, node (MCP servers), tmux server/clients, sshd, the live claude
# process tree, docker.
#
# Usage: scripts/process-cleanup.sh [--dry-run]
set -uo pipefail
DRY="${1:-}"

count() { ps -u "$(id -u)" --no-headers -o pid= | wc -l; }
echo "> processes before: $(count)"

kill_pat() {
  local label="$1"; shift
  local pids
  pids=$(pgrep -u "$(id -u)" -f "$@" || true)
  if [ -z "$pids" ]; then echo "  $label: none"; return; fi
  local n
  n=$(echo "$pids" | wc -l)
  if [ "$DRY" = "--dry-run" ]; then
    echo "  $label: would kill $n"
  else
    echo "$pids" | xargs -r kill 2>/dev/null
    echo "  $label: killed $n"
  fi
}

# Wave 1: unambiguous leaks.
kill_pat "dart analysis servers" 'dartdev_ao|dart .*analysis_server'
kill_pat "gradle daemons"        'GradleDaemon'
kill_pat "headless chrome"       'chrome.*--headless'
kill_pat "chrome crashpad"       'chrome_crashpad'
kill_pat "stale task tails"      'tail -f /tmp/claude|tail -F /tmp/claude|tail -f /tmp/mobissh|tail -n .* -f'

sleep 2
echo "> processes after wave 1: $(count)"

# Wave 2: orphaned script pipelines — bash/tee/sort/sleep whose parent is PID 1
# and whose cmdline points at repo scripts or agent worktrees. Conservative:
# requires BOTH orphaned (ppid=1) AND a recognizable script path.
for pid in $(ps -u "$(id -u)" --no-headers -o pid,ppid,comm | awk '$2==1 && ($3=="bash"||$3=="tee"||$3=="sort"||$3=="sleep"||$3=="head"){print $1}'); do
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
  case "$cmd" in
    *scripts/*|*worktrees/agent-*|*tee -a /tmp/mobissh*|*tee -a /tmp/claude*|"sleep "*)
      if [ "$DRY" = "--dry-run" ]; then echo "  orphan would-kill: $pid $cmd"; else kill "$pid" 2>/dev/null; fi
      ;;
  esac
done

sleep 2
echo "> processes after wave 2: $(count)"
echo "+ done. Emulator/adb/socat/node/tmux untouched."
