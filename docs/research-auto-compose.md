# Research: Auto-Compose Prompt Detection Heuristics

Research spike for issue #10: automatically switching input modes based on
whether the terminal is showing a shell prompt vs command output.

## 1. What Patterns Identify a Shell Prompt?

Common trailing characters at the end of a prompt line:

| Pattern | Shell / Context |
|---------|----------------|
| `$ ` | bash, zsh, sh (non-root) |
| `# ` | bash, zsh, sh (root) |
| `% ` | zsh (default), csh, tcsh |
| `> ` | PS2 continuation, fish, PowerShell |
| `>>> ` | Python REPL |
| `... ` | Python continuation |
| `: ` | password/passphrase prompts |

PS1 is fully user-configurable. Common structures include:
- `user@host:path$ ` (Debian default)
- `[user@host path]$ ` (RHEL/CentOS default)
- Multi-line prompts where `$` appears on line 2 (oh-my-zsh, Starship, Powerlevel10k)
- Right-aligned prompts (zsh RPROMPT)
- Prompts with ANSI color codes wrapping the trailing character

## 2. Reading the Current Terminal Line from xterm.js

The existing codebase already uses this pattern in `_checkPasswordPrompt()` (ime.ts:26-31):

```typescript
const buf = appState.terminal.buffer.active;
const lastLine = buf.getLine(buf.cursorY)?.translateToString(true) ?? '';
```

Key xterm.js `IBuffer` API surface:
- `buffer.active` returns the active buffer (normal or alt-screen)
- `buffer.active.cursorX` -- cursor column (0 to terminal.cols)
- `buffer.active.cursorY` -- cursor row (0 to terminal.rows - 1)
- `buffer.active.baseY` -- scroll offset of the viewport
- `getLine(y)` returns `IBufferLine | undefined`
- `IBufferLine.translateToString(trimRight?)` -- gets text content
- `IBufferLine.getCell(x)` -- per-cell access (char, width, attrs)

The cursor position is relative to the viewport, not the scrollback. When at
the bottom of output, `cursorY` is at the last used row.

To detect prompt vs output, the useful signals are:
- `cursorX` -- where the cursor sits after the prompt text
- `cursorY` -- whether cursor is on the last line
- Line content to the left of `cursorX`

## 3. Prompt vs Output That Happens to End with `$`

A line ending with `$` in command output (e.g., `ls` showing a filename, `env`
printing `PATH=/usr/bin$`) is visually indistinguishable from a prompt without
additional signals. Key differentiators:

**Cursor position:** After a prompt, the cursor sits immediately after the
trailing character (e.g., `user@host:~$ _` where `_` is cursor). After output,
the cursor is typically at column 0 of the next line, or the output continues.

**Line position in viewport:** A prompt is usually the last non-empty line
visible, with the cursor on it. Output lines scroll past.

**Timing:** Prompts appear after command output finishes. A heuristic could
debounce: if the terminal has been idle (no new data) for 100-200ms and the
cursor is on a line matching a prompt pattern, it is likely a prompt.

**Alt-screen buffer:** Programs like vim, less, htop use the alt buffer.
Prompt detection should only apply to the normal buffer.

## 4. How Popular Terminals Detect Prompts

### OSC 133 (Semantic Prompts / FinalTerm Protocol)

The industry-standard approach. Four escape sequences mark the prompt lifecycle:

| Sequence | Meaning |
|----------|---------|
| `OSC 133 ; A ST` | Start of prompt |
| `OSC 133 ; B ST` | End of prompt (user input begins) |
| `OSC 133 ; C ST` | Command output starts |
| `OSC 133 ; D [; exitcode] ST` | Command output ends |

Where `OSC` = `\x1b]` and `ST` = `\x1b\\` or `\x07` (BEL).

Terminals using this: iTerm2, Windows Terminal, VS Code integrated terminal,
kitty, WezTerm, Ghostty, Contour.

### iTerm2 Shell Integration

iTerm2 pioneered semantic prompts. Beyond OSC 133, it uses OSC 1337 for:
- `CurrentDir=path` -- working directory
- `ShellIntegrationVersion=N` -- version negotiation
- `RemoteHost=user@host` -- identity

### Windows Terminal

Uses the same OSC 133 sequences. Documents them in their shell integration
tutorial. Bash/zsh/PowerShell all supported.

### VS Code Terminal

Registers OSC 133 handlers and uses them for "run recent command", command
navigation, and decorating command output with exit status marks.

## 5. OSC 133 Shell Compatibility

| Shell | Native Support | Config Required |
|-------|---------------|-----------------|
| bash | No | Add to `PROMPT_COMMAND` and `DEBUG` trap |
| zsh | No | Add to `precmd` and `preexec` hooks |
| fish | Yes (3.6+) | Built-in, emits OSC 133 by default |
| tcsh | No | Add to `precmd`/`postcmd` aliases |
| PowerShell | Yes (7.2+) | Built-in when `$PSStyle.OutputRendering` set |

**bash setup** (add to .bashrc):
```bash
PS0='\e]133;C\a'
PS1='\e]133;A\a\u@\h:\w\$ \e]133;B\a'
PROMPT_COMMAND='echo -ne "\e]133;D;$?\a"'
```

**zsh setup** (add to .zshrc):
```zsh
precmd() { print -Pn '\e]133;A\a' }
# PS1 ends with: %{\e]133;B\a%}
preexec() { print -Pn '\e]133;C\a' }
```

The key problem: MobiSSH connects to remote hosts where the user may not have
configured shell integration. OSC 133 requires cooperation from the remote
shell.

## 6. False Positive Risk Assessment

### Regex heuristic risks

| Scenario | Risk | Severity |
|----------|------|----------|
| `env` output: `OLDPWD=/home/user$` | Line ends with `$` | Medium |
| `echo '$'` output | Bare `$` at end of line | Medium |
| `git log --oneline` output ending with `$` | Rare but possible | Low |
| Multi-line prompt (line 1: info, line 2: `$ `) | Partial match | Medium |
| Password prompt (`Password: `) | Triggers compose when direct is better | High |
| `mysql>` or `psql#` prompts | Non-standard patterns | Medium |
| `>>>` Python REPL | Different editing semantics | Low |

### OSC 133 risks

| Scenario | Risk | Severity |
|----------|------|----------|
| Remote shell not configured | No sequences emitted, no detection | N/A (graceful) |
| tmux/screen stripping sequences | Sequences may not pass through | Medium |
| Nested SSH sessions | Inner shell may emit, confusing state | Low |

OSC 133 has zero false positives by design -- if the shell emits the sequence,
it is definitively a prompt. The failure mode is false negatives (no detection),
which is safe.

## 7. What Should Auto-Compose Do?

### Option A: Auto-switch IME mode on prompt detection
When a prompt is detected, automatically enable compose mode (swipe-friendly
textarea). When command output is flowing, switch to direct mode.

**Pros:** Seamless UX, no manual toggle needed.
**Cons:** Jarring if detection flickers. Password prompts should stay in direct
mode (already handled by `_checkPasswordPrompt`).

### Option B: Visual indicator only
Show a small icon or color change in the key bar when a prompt is detected.
User still toggles compose mode manually.

**Pros:** No false-positive risk to input behavior. Informational.
**Cons:** Doesn't save the user any taps.

### Option C: Hybrid -- auto-switch with manual override
Auto-switch on prompt, but if the user manually toggles, stick with their
choice until the next prompt cycle.

**Recommended:** Option C. It provides the convenience of auto-switching while
respecting explicit user intent.

## Design Proposal

### Approach Comparison

**Regex heuristic:**
- Works immediately on any remote host
- No shell configuration required
- False positive risk is real but manageable with cursor-position checks
- Can be combined with idle-time debouncing (100-200ms no terminal data)

**OSC 133:**
- Zero false positives
- Requires remote shell configuration (users must add lines to .bashrc/.zshrc)
- MobiSSH could provide a setup helper or detect when sequences are present
- xterm.js already has `parser.registerOscHandler()` -- trivial to hook

**Recommendation: Implement both, OSC 133 first.**

OSC 133 is the correct long-term solution. It is already the industry standard
across iTerm2, Windows Terminal, VS Code, kitty, WezTerm, and Ghostty. The
xterm.js `registerOscHandler` API makes implementation straightforward -- the
codebase already registers OSC 9 and OSC 777 handlers in `terminal.ts`.

The regex heuristic should be Phase 2, activated only when OSC 133 sequences
have not been detected for a session. This avoids false positives for users
who have shell integration configured and provides a fallback for those who
don't.

### Proposed Function Signatures

```typescript
// Phase 1: OSC 133 state tracking
interface PromptState {
  atPrompt: boolean;        // true between OSC 133;B and OSC 133;C
  lastExitCode: number | null;
  oscDetected: boolean;     // true once any OSC 133 sequence is seen
}

function initPromptDetection(terminal: Terminal): PromptState;

// Phase 2: Regex fallback (only when oscDetected === false)
function isAtPromptHeuristic(terminal: Terminal): boolean;
```

**`initPromptDetection`** registers four OSC 133 handlers and returns a
reactive state object. The IME layer observes `atPrompt` to auto-switch
compose mode.

**`isAtPromptHeuristic`** reads the current buffer line at `cursorY`,
checks if the text left of `cursorX` matches prompt patterns, and
applies debouncing. Only called when `oscDetected` is false.

### Regex Heuristic Patterns (Phase 2)

```typescript
// Matches common prompt endings, allowing ANSI color codes before the
// trailing character. Anchored to cursorX position, not line end.
const PROMPT_RE = /(?:\$|#|%|>|>>>)\s*$/;

function isAtPromptHeuristic(terminal: Terminal): boolean {
  const buf = terminal.buffer.active;
  // Only check normal buffer (not alt-screen: vim, less, htop)
  if (buf.type !== 'normal') return false;
  const line = buf.getLine(buf.cursorY);
  if (!line) return false;
  // Get text from start of line to cursor position
  const textBeforeCursor = line.translateToString(true, 0, buf.cursorX);
  if (!textBeforeCursor.trim()) return false;
  // Skip password prompts (handled separately by _checkPasswordPrompt)
  if (/(?:password|passphrase|PIN)[^:]*:\s*$/i.test(textBeforeCursor)) return false;
  return PROMPT_RE.test(textBeforeCursor);
}
```

### Implementation Order

1. **OSC 133 handler** in `terminal.ts` using `registerOscHandler(133, ...)`
   - Track `PromptState` in `appState`
   - Wire to compose-mode toggle in IME layer
2. **Idle debounce** -- only evaluate prompt state after 150ms of no terminal data
3. **Regex fallback** -- activate when no OSC 133 seen after first command
4. **User override** -- manual compose toggle sticks until next OSC 133;A/D cycle
5. **Setup helper** -- settings panel snippet to add OSC 133 to remote .bashrc/.zshrc
