# Install MobiSSH notification hook on a Claude Code instance

Paste the prompt below into a fresh Claude Code session running anywhere
that can reach your MobiSSH server (over Tailscale, LAN, or localhost).
The agent will detect existing hooks, install or upgrade `mobissh-bridge.sh`
in `~/.claude/hooks/`, and wire it into `~/.claude/settings.json` —
coexisting with any other hooks already in place.

> **Naming convention:** All MobiSSH hook artifacts are prefixed
> `mobissh-` so an `ls ~/.claude/hooks/` makes it obvious which scripts
> belong to MobiSSH. Older installs that used unprefixed names like
> `notify-bell.sh` are migrated to `mobissh-bridge.sh` automatically.

## Prompt to paste

> Install or upgrade the MobiSSH notification hook for this Claude Code
> instance. My MobiSSH server URL is
> `<paste-your-https-url-here>` (e.g. `https://mobissh.tailbe5094.ts.net`).
>
> ### Phase 1 — Detect prior state
>
> Before writing anything, inspect:
>
> 1. `~/.claude/hooks/mobissh-bridge.sh` — does it already exist?
>    - **Yes:** this is an upgrade. Plan to overwrite the script (the
>      remote copy is the canonical version) and verify the
>      `settings.json` wiring still points at it.
>    - **No:** this is a fresh install.
>
> 2. `~/.claude/hooks/notify-bell.sh` — legacy MobiSSH name from earlier
>    installs.
>    - **Yes:** plan to install `mobissh-bridge.sh` alongside, then
>      remove `notify-bell.sh` AFTER updating `settings.json` to the
>      new path.
>
> 3. `~/.claude/settings.json` `hooks` block — for each of `Stop`,
>    `SubagentStop`, `Notification`, `PermissionRequest` enumerate the
>    currently-registered command(s):
>    - If the only command is `mobissh-bridge.sh` or `notify-bell.sh`,
>      it's a MobiSSH-only setup → safe to replace with the canonical
>      `mobissh-bridge.sh` path.
>    - If there are OTHER commands too (a personal `tts.sh`, a
>      `slack-notify.sh`, anything not prefixed `mobissh-`), this is a
>      mixed setup → APPEND `mobissh-bridge.sh` to the list, do not
>      remove the other entries.
>    - If the event has no hooks at all → install fresh.
>
> 4. Project-scoped configs: walk parents from `pwd` up to `/`, looking
>    for `.claude/settings.json` and `.claude/settings.local.json` that
>    define a `hooks` block. Apply the same per-event reconciliation to
>    each one. (Project hooks override the global one — if MobiSSH is
>    installed globally but a project config overrides Stop without
>    listing mobissh-bridge.sh, MobiSSH won't fire from that project.)
>
> Print a one-paragraph summary of what you found before proceeding to
> Phase 2 so the user can confirm.
>
> ### Phase 2 — Install / upgrade the script
>
> Fetch the canonical script content from the server and write it to
> `~/.claude/hooks/mobissh-bridge.sh`:
>
> ```bash
> mkdir -p ~/.claude/hooks
> curl -sS --max-time 10 \
>   "${MOBISSH_URL}/install-hooks/mobissh-bridge.sh" \
>   -o ~/.claude/hooks/mobissh-bridge.sh
> chmod +x ~/.claude/hooks/mobissh-bridge.sh
> ```
>
> The script comes from the running MobiSSH server itself, so it stays
> in sync with whatever the server expects. Do not embed a copy in your
> output — always fetch the URL.
>
> Verify the script: it must contain `approval-gate` (the v2
> poll-based PermissionRequest gate) and `hookHost` (the field that
> lets notification taps route back to the originating SSH session):
>
> ```bash
> grep -q approval-gate ~/.claude/hooks/mobissh-bridge.sh && \
> grep -q hookHost ~/.claude/hooks/mobissh-bridge.sh && \
>   echo "OK: mobissh-bridge.sh has all required features"
> ```
>
> If either grep fails, the bundled image is stale — tell the user and
> stop.
>
> ### Phase 3 — Reconcile settings.json
>
> For every hook event in `Stop`, `SubagentStop`, `Notification`,
> `PermissionRequest`:
>
> ```jq
> # Idempotent: only adds mobissh-bridge.sh if it isn't already listed.
> # Preserves any non-mobissh entries (other people's hooks).
> # Removes any legacy notify-bell.sh entry.
> ```
>
> Use `jq` to update `~/.claude/settings.json` (and any project-scoped
> configs you found in Phase 1) with this transform:
>
> 1. Read the array of hook entries for the event (or `[]` if absent).
> 2. Drop any entry whose command path ends in `notify-bell.sh` (legacy).
> 3. If no remaining entry's command path ends in `mobissh-bridge.sh`,
>    append `{type:"command", command:"~/.claude/hooks/mobissh-bridge.sh"}`.
> 4. Write back atomically (`tmp` file then `mv`).
>
> Pseudocode (write the actual jq invocation per event):
>
> ```bash
> jq '.hooks.Stop = (
>   ((.hooks.Stop // []) | map(select(.hooks[]?.command | test("notify-bell\\.sh$") | not)))
>   | if any(.hooks[]?.command; test("mobissh-bridge\\.sh$"))
>     then .
>     else . + [{matcher:"", hooks:[{type:"command", command:"~/.claude/hooks/mobissh-bridge.sh"}]}]
>     end
> )' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
> ```
>
> Then remove the legacy script if it exists and is no longer
> referenced by any settings file:
>
> ```bash
> if [[ -f ~/.claude/hooks/notify-bell.sh ]] && \
>    ! grep -rq notify-bell ~/.claude *.claude/settings*.json 2>/dev/null; then
>   rm ~/.claude/hooks/notify-bell.sh
>   echo "Removed legacy ~/.claude/hooks/notify-bell.sh"
> fi
> ```
>
> ### Phase 4 — Verify end-to-end
>
> 1. **Local script execution.** Pipe a synthetic PermissionRequest
>    payload through the hook and confirm it returns a valid decision:
>
>    ```bash
>    echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo verify"}}' \
>      | timeout 15 ~/.claude/hooks/mobissh-bridge.sh \
>      | jq '.hookSpecificOutput.decision.behavior'
>    ```
>
>    Expected: `"allow"` or `"deny"` (whatever the server's default
>    mode is). If the script hangs, the server is unreachable from this
>    host — diagnose with `curl -sS ${MOBISSH_URL}/version`.
>
> 2. **Server reachability.**
>
>    ```bash
>    curl -sS "${MOBISSH_URL}/version" | jq .
>    ```
>
>    Expected: `{"version":"1.3.0","hash":"..."}`.
>
> 3. **Live notification.** Trigger a turn-end (or `/clear` then send a
>    short message) — the user's MobiSSH PWA should buzz once. If the
>    user is not currently looking at the PWA, tapping the notification
>    should focus the app and switch to whichever SSH session matches
>    `$(hostname)`.
>
> ### Phase 5 — Report
>
> Summarize, for each settings file you touched:
>
> - Path
> - For each event: was it (a) freshly installed, (b) already present
>   and left alone, (c) upgraded from `notify-bell.sh` to
>   `mobissh-bridge.sh`, or (d) coexists with non-MobiSSH entries.
>
> Tell the user to restart any running Claude Code sessions for the
> hooks to take effect.

## What this script does

`mobissh-bridge.sh` is a single hook called on every Claude Code event:

| Hook event          | Behavior                                          |
|---------------------|---------------------------------------------------|
| `Stop`              | Fire-and-forget POST → `${MOBISSH_URL}/api/hook`. Phone shows "Claude is ready" (40ms vibration). |
| `SubagentStop`      | Same; phone shows "Subagent finished" (60-40-60). |
| `Notification`      | Same; phone shows "Claude Code" (20ms).           |
| `PermissionRequest` | **Blocking gate** at `${MOBISSH_URL}/api/approval-gate?hookVersion=2`. Hook polls until phone responds yes/no, OR the server's default mode (allow/deny) kicks in if no clients are connected. 115s timeout. |

Every payload includes `hookHost: $(hostname)` so notification taps on
the phone can route back to the originating SSH session.

## Coexistence rules

- **MobiSSH hooks NEVER overwrite non-MobiSSH hooks.** If you have your
  own Stop hook that does TTS or Slack, MobiSSH appends to the list —
  both fire on every Stop event.
- **MobiSSH hooks DO replace older MobiSSH hooks.** `notify-bell.sh` is
  the legacy name; it gets migrated to `mobissh-bridge.sh` on upgrade.
- **All MobiSSH artifacts are prefixed `mobissh-`.** If you see a hook
  in `~/.claude/hooks/` without that prefix, it's not from MobiSSH.

## Multi-instance setup

Install the same hook on every machine that runs Claude Code. The
`hookHost: $(hostname)` field lets the phone tell them apart and route
each notification tap to the right SSH session.

## Uninstall

```bash
rm ~/.claude/hooks/mobissh-bridge.sh
# Then edit ~/.claude/settings.json (and any project configs) to remove
# entries whose command ends in mobissh-bridge.sh.
```

If you have non-MobiSSH hooks on the same events, the entries you
added will stay in place — only the mobissh-bridge.sh entries are
removed.
