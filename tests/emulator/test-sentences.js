/**
 * tests/emulator/test-sentences.js
 *
 * Realistic IME test data mined from actual mobile input patterns.
 * Source: GitHub issue #139 comments (flavordrake), real swipe/voice bug reports.
 *
 * Data variety rules:
 *   - Long sentences (15+ words) for compose/preview integration
 *   - Single words and short fragments for edge cases
 *   - Slash commands, number responses, skill invocations
 *   - Escape sequences and ctrl combos typed on mobile
 *   - Technical terms and shell syntax (triggers Gboard autocorrect)
 *   - Punctuation-heavy input (commas, semicolons, parens, pipes)
 */

// ── Commit messages / descriptions (natural mobile typing) ───────────────────

const COMMIT_SENTENCES = [
  'fix the direct mode enter key so it actually sends a carriage return on gboard, the issue was that enterkeyhint was missing from the password field.',
  'I want to capture all of these individually then turn them into aggressive test cases, something is off in our preview composer and key interaction behaviors.',
  'the preview does appear but only the first word is captured then nothing else comes through, I think a timer is canceling compose mode prematurely.',
  'the websocket url uses same-origin detection via getDefaultWsUrl which works in codespaces with wss and local with ws, no manual config needed.',
  'run scripts/test-headless.sh to verify the playwright tests pass, there should be about 700 passing and only the tooltip tests failing which are pre-existing.',
];

// ── Shell prompts / interactive input ────────────────────────────────────────

const SHELL_SENTENCES = [
  'tail -f /var/log/syslog | grep -i error, then check if the server restarted properly and verify the version hash matches what we deployed.',
  'docker logs mobissh-prod --tail 50 and look for any websocket connection drops, especially the ones that say derp does not know about peer.',
  'cd /home/dev/workspace/mobissh && git log --oneline -10 to see the recent commits, then cherry-pick the fix if it looks right.',
  'set the cache control header to no-store on all static responses, the service worker uses network-first so we never want stale cached files.',
  'ssh into the tailscale node at 100.64.0.1 and check if the container is healthy, use docker ps to see the status and docker logs to check for errors.',
];

// ── Bug descriptions typed at a prompt ───────────────────────────────────────

const BUG_SENTENCES = [
  'voice typing often disables for some reason after the first word, then if I keep talking and hit the check box to commit nothing happens but if I type space or enter it does.',
  'backspace stops functioning when I try to fix a partial word with a correction appended, it inserts safetyly but should be transformed into four backspaces followed by ly.',
  'when preview is on and I swipe type back over a word the cursor stops at the beginning of the preview field, it should keep sending backspace to the terminal once the field is empty.',
  'something is fighting or canceling compose mode prematurely lets figure out why, the textarea goes blank after about two seconds even though I am still typing.',
];

// ── Autocorrect-prone sentences ──────────────────────────────────────────────
// Words that Gboard commonly autocorrects mid-swipe: technical terms, CLI flags,
// intentional misspellings that test the correction→diff pipeline.

const AUTOCORRECT_SENTENCES = [
  'the autocorrect changed teh to the and recieve to receive mid-sentence, which is exactly what we need to verify in our IME pipeline for corrections.',
  'we need to figure out a better job merging corrected text because gboard fights you on technical terms like nginx, systemctl, and compositionend.',
  'type safetly then tap the suggestion bar to correct it to safely, the app should send four backspaces followed by ely to fix the terminal output.',
  'backspace stops functioning when I try to fix a partial word with a correction appended, it inserts safetyly but should be transformed into four backspaces followed by ly.',
];

// ── Short inputs: single words, numbers, slash commands ──────────────────────
// These test IME handling of minimal input — Gboard behaves differently for
// single-word compositions vs multi-word swipes.

const SHORT_INPUTS = [
  'ls',
  'y',
  '3',
  'exit',
  '/develop 148',
  '/integrate',
  '/delegate 16,44,70',
  'yes',
  'n',
  '127.0.0.1',
  'testuser@10.0.2.2',
  'grep -r "TODO" .',
];

// ── Control sequences typed on mobile keyboards ─────────────────────────────
// Ctrl+C, Ctrl+D, Ctrl+Z, Escape — must work in compose mode too.
// The IME detects these and forwards them to SSH without requiring a mode switch.
// Gboard doesn't have native ctrl/esc keys; they go through our sticky modifier.

const CONTROL_SEQUENCES = [
  '\x03',       // Ctrl+C (SIGINT)
  '\x04',       // Ctrl+D (EOF)
  '\x1a',       // Ctrl+Z (SIGTSTP)
  '\x1b',       // Escape
  '\x1b[A',     // Up arrow (escape sequence)
  '\x1b[B',     // Down arrow
  '\x1b[C',     // Right arrow
  '\x1b[D',     // Left arrow
  '\x01',       // Ctrl+A (beginning of line)
  '\x05',       // Ctrl+E (end of line)
  '\x0c',       // Ctrl+L (clear screen)
  '\x17',       // Ctrl+W (delete word backward)
];

// ── Convenience: flat array of all sentences for index-based access ──────────

const ALL_SENTENCES = [
  ...COMMIT_SENTENCES,
  ...SHELL_SENTENCES,
  ...BUG_SENTENCES,
  ...AUTOCORRECT_SENTENCES,
];

module.exports = {
  COMMIT_SENTENCES,
  SHELL_SENTENCES,
  BUG_SENTENCES,
  AUTOCORRECT_SENTENCES,
  SHORT_INPUTS,
  CONTROL_SEQUENCES,
  ALL_SENTENCES,
};
