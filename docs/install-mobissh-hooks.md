# Install MobiSSH haptic notifications on a Claude Code instance

Paste the prompt below into a fresh Claude Code session running anywhere
that can reach your MobiSSH server (over Tailscale, LAN, or localhost).
The agent will create the hook script, wire it into `~/.claude/settings.json`,
and verify the install.

## Prompt to paste

> Install the MobiSSH notification hook. My MobiSSH server URL is
> `<paste-your-https-url-here>` (e.g. `https://mobissh.tailbe5094.ts.net`).
>
> Create `~/.claude/hooks/notify-bell.sh` with the script below.
> Make it executable.
>
> Then merge the `hooks` block below into `~/.claude/settings.json`
> (preserve any existing `hooks`, `permissions`, etc. — don't clobber).
>
> The script reads each Claude Code hook event (Stop, SubagentStop,
> Notification, PermissionRequest) from stdin as JSON, adds an
> `event` field, and POSTs the payload to `${MOBISSH_URL}/api/approval`.
> The MobiSSH PWA on my phone receives the event via SSE and fires
> a per-event haptic + notification:
>
> | Event             | Title              | Vibration      |
> |-------------------|--------------------|----------------|
> | Stop              | "Claude is ready"  | 40ms           |
> | SubagentStop      | "Subagent finished"| 60-40-60       |
> | Notification      | "Claude Code"      | 20ms           |
> | PermissionRequest | (modal prompt)     | 100-50-100     |
>
> ### `~/.claude/hooks/notify-bell.sh`
>
> ```bash
> #!/usr/bin/env bash
> # MobiSSH notification hook. Forwards every Claude Code hook event
> # to the MobiSSH PWA so it can fire a haptic notification on the phone.
> #
> # Configured per-host. Set MOBISSH_URL to the HTTPS endpoint of your
> # MobiSSH server (Tailscale-served, typically).
>
> set -euo pipefail
>
> MOBISSH_URL="${MOBISSH_URL:-https://CHANGE-ME.tailbe5094.ts.net}"
>
> # 2-second dedup so rapid-fire events don't spam the phone
> LOCKFILE="/tmp/.claude-mobissh-notify-lock"
> COOLDOWN=2
> if [[ -f "$LOCKFILE" ]]; then
>   LAST=$(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0)
>   NOW=$(date +%s)
>   if (( NOW - LAST < COOLDOWN )); then
>     cat > /dev/null
>     exit 0
>   fi
> fi
> touch "$LOCKFILE"
>
> INPUT=$(cat)
> EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
> [[ -z "$EVENT" ]] && exit 0
>
> # Forward raw event JSON with `event` field added
> BRIDGE_JSON=$(echo "$INPUT" | jq -c --arg event "$EVENT" '. + {event: $event}' 2>/dev/null \
>   || printf '{"event":"%s"}' "$EVENT")
>
> curl -sS --max-time 2 -X POST -H 'Content-Type: application/json' \
>   -d "$BRIDGE_JSON" \
>   "${MOBISSH_URL}/api/approval" >/dev/null 2>&1 || true
>
> # Local terminal fallback: walk process tree for /dev/pts/* and ring bell
> PID=$$
> while [[ $PID -gt 1 ]]; do
>   PID=$(awk '{print $4}' /proc/$PID/stat 2>/dev/null) || break
>   TTY=$(readlink /proc/$PID/fd/0 2>/dev/null)
>   if [[ "$TTY" == /dev/pts/* && -w "$TTY" ]]; then
>     printf '\a' > "$TTY" 2>/dev/null
>     exit 0
>   fi
> done
>
> exit 0
> ```
>
> ### `~/.claude/settings.json` — merge into `hooks`
>
> ```json
> {
>   "hooks": {
>     "Stop": [
>       { "matcher": "", "hooks": [
>         { "type": "command", "command": "~/.claude/hooks/notify-bell.sh" }
>       ]}
>     ],
>     "SubagentStop": [
>       { "matcher": "", "hooks": [
>         { "type": "command", "command": "~/.claude/hooks/notify-bell.sh" }
>       ]}
>     ],
>     "Notification": [
>       { "matcher": "", "hooks": [
>         { "type": "command", "command": "~/.claude/hooks/notify-bell.sh" }
>       ]}
>     ],
>     "PermissionRequest": [
>       { "matcher": "", "hooks": [
>         { "type": "command", "command": "~/.claude/hooks/notify-bell.sh" }
>       ]}
>     ]
>   }
> }
> ```
>
> After install, verify by:
> 1. Running `~/.claude/hooks/notify-bell.sh < <(echo '{"hook_event_name":"Stop"}')`
>    — should exit 0 with no errors.
> 2. Triggering a turn-end in Claude Code; my phone should buzz once.

## What gets sent

Each event POSTs to `${MOBISSH_URL}/api/approval` with `Content-Type:
application/json`. The body is the raw Claude Code hook input (whatever
fields Claude Code provides — typically `hook_event_name`, `session_id`,
`cwd`, `tool_name`, `tool_input`, etc.) with an additional `event` field
copied from `hook_event_name` for compatibility with older PWA builds.

The MobiSSH server logs each event:
```
[hook] event="Stop" tool="" detail="" desc=""
[hook] → SSE event="hook" (isApproval=false, clients=N)
```

PermissionRequest takes a different SSE channel (`approval`) so it can
drive the phone's modal approval UI; everything else flows through the
generic `hook` channel and only fires the haptic + drawer entry.

## Multi-instance setup

If you run Claude Code on several machines (laptop, dev container, CI),
install the hook on each one with the same `MOBISSH_URL`. All of them
will fire haptics on the same phone — useful for monitoring multiple
parallel sessions.

For per-instance distinction, extend the hook to include a host tag:
```bash
HOSTNAME_TAG=$(hostname -s)
BRIDGE_JSON=$(echo "$INPUT" | jq -c --arg event "$EVENT" --arg host "$HOSTNAME_TAG" \
  '. + {event: $event, host: $host}')
```
The PWA will display the host in the notification body.

## Uninstall

Remove the four entries from `~/.claude/settings.json` `hooks` block,
or `rm ~/.claude/hooks/notify-bell.sh`. The script failing fast (curl
returns non-zero, suppressed by `|| true`) makes uninstall optional —
but the dedup lockfile and curl call add ~50ms per event.
