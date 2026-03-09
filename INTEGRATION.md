# MobiSSH Coding Agent Integration

MobiSSH can receive terminal bell notifications from coding CLI agents running on the
same machine. When an agent needs input (permission prompt, idle, task complete), a hook
script writes `\a` to the terminal. MobiSSH's xterm.js parser triggers a ServiceWorker
notification, alerting you on your phone.

This works with any agent that supports shell hooks or notification callbacks.

## How it works

1. Agent fires a hook event (e.g., permission request, stop)
2. Hook script walks `/proc` to find the ancestor's `/dev/pts/*` device
3. Script writes `\a` (bell) to that device
4. MobiSSH's terminal parser receives the bell and fires a push notification

## notify-bell.sh

Save this as `~/.claude/hooks/notify-bell.sh` (or anywhere; adjust paths below):

```bash
#!/bin/bash
# Bell notification for MobiSSH terminal.
# Walks the process tree to find the ancestor's /dev/pts/* device,
# since hook subprocesses have no controlling terminal.

LOCKFILE="/tmp/.claude-notify-lock"
COOLDOWN=2

if [[ -f "$LOCKFILE" ]]; then
  LAST=$(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if (( NOW - LAST < COOLDOWN )); then exit 0; fi
fi
touch "$LOCKFILE"

# Consume stdin (hooks send JSON on stdin; we only need the bell)
cat > /dev/null

# Walk process tree to find a writable /dev/pts/* device
PID=$$
while [[ $PID -gt 1 ]]; do
  PID=$(awk '{print $4}' /proc/$PID/stat 2>/dev/null) || break
  TTY=$(readlink /proc/$PID/fd/0 2>/dev/null)
  if [[ "$TTY" == /dev/pts/* && -w "$TTY" ]]; then
    printf '\a' > "$TTY" 2>/dev/null
    exit 0
  fi
done

exit 0
```

```bash
chmod +x ~/.claude/hooks/notify-bell.sh
```

## Claude Code

Add to `~/.claude/settings.json` (global) or `.claude/settings.json` (per-project):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify-bell.sh" }]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify-bell.sh" }]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify-bell.sh" }]
      }
    ]
  }
}
```

Or use the interactive menu: run `claude` then type `/hooks`.

**Hook events:**
- `Stop` -- agent finished its turn, waiting for you
- `Notification` -- agent needs attention (idle, auth, etc.)
- `PermissionRequest` -- agent needs you to approve a tool call

## Codex (OpenAI)

Add to `~/.codex/config.toml`:

```toml
notify = ["bash", "-c", "~/.claude/hooks/notify-bell.sh"]
```

## Gemini CLI

Add to `~/.gemini/settings.json`:

```json
{
  "hooks": [
    {
      "type": "BeforeTool",
      "toolName": "ask_user",
      "command": ["bash", "-c", "~/.claude/hooks/notify-bell.sh"]
    }
  ]
}
```

## OpenCode

Save as `~/.config/opencode/plugins/mobissh-notify.js`:

```javascript
export default function plugin() {
  return {
    tool: {
      execute: {
        before: async ({ tool }) => {
          if (tool.name === 'question') {
            const { execFile } = await import('child_process');
            execFile(process.env.HOME + '/.claude/hooks/notify-bell.sh', { env: process.env }, () => {});
          }
        },
      },
    },
  };
}
```

## Limitations

- The bell script requires Linux `/proc` filesystem (works on Linux servers, WSL, Docker
  with host PID namespace). macOS needs a different TTY detection approach.
- Inside tmux, the bell triggers tmux's bell handling (visual bell, window flag, etc.)
  rather than going directly to the terminal emulator.
- The 2-second cooldown deduplicates rapid-fire events but means you won't get
  separate notifications for events within 2 seconds of each other.
- Hook configuration is manual per-agent. There is no unified plugin system across
  coding agents yet. Claude Code has an emerging plugin framework that may support
  bundled hooks in the future.

## Future

Once coding agent plugin ecosystems mature, we plan to offer one-click integration
directly from MobiSSH's settings panel. The current manual approach will continue
to work regardless.
