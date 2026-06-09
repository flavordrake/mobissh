# MobiSSH Constitution

**v1 — 2026-06-09.** The inviolable principles every agent reads FIRST. These are
ranked most-costly / most-violated first. They **override defaults**. When a rule file,
skill, or habit conflicts with an article here, this document wins. Detail lives in
`.claude/rules/*.md` and the `memory/feedback_*.md` files — this is the canonical short list.

---

### 1. Command hygiene — one script per Bash call
No `&&` / `;` chains, no compound commands, no shell redirects (`>`, `2>`), no heredocs.
Use the wrapper scripts (`gh-ops.sh`, `ship-native.sh`, `container-ctl.sh`, `bot-branch.sh`),
never raw `gh` or raw `git`. Create files with the Write tool, then pass `--body-file`.
**Why:** every violation is a per-invocation approval prompt on mobile; chained commands
mask failures (a `|| true` swallows the real exit code). Speed-reading approvals is how the
main repo once got deleted.

### 2. Security — block, don't degrade
Never store secrets (passwords, keys, passphrases) in plaintext. Use the encrypted vault
(PasswordCredential + AES-GCM). If secure storage is unavailable, **block the feature** —
do not fall back to plaintext with a warning. No secrets in code, logs, commits, issue
bodies, or uploads (scrub telemetry/screenshots). **Why:** a single plaintext leak is
unrecoverable; a blocked feature is a known gap.

### 3. No orchestrator git/ship while agents run
Do NOT commit, push, `ship-native.sh`, `gh-ops.sh integrate`, or hold uncommitted edits
while ANY develop/gater agent is active. Wait for all agents to finish; verify
`git branch --show-current` == `main` + clean tree first. **Why:** bot agents
`git reset --hard origin/main` the MAIN checkout to run their gate, hijacking your branch
and silently clobbering uncommitted work.

### 4. Agents gate inside their own worktree
A develop/gater agent runs the gate as a RELATIVE path from its worktree root
(`scripts/native-fast-gate.sh`). NEVER `git checkout` / `reset --hard` / `cherry-pick` the
MAIN checkout, and NEVER invoke the gate via its main-repo absolute path. **Why:** touching
main hijacks the orchestrator's tree and discards its uncommitted work (#537).

### 5. Know when to quit
After 2 fix cycles without a stable result, or when each fix introduces a new failure mode
(the bug is migrating, not narrowing), or when fixes scatter guards into unrelated modules —
**STOP and reassess**. Branch the work off, document what failed, file a fresh-approach issue.
**Why:** patches don't fix structural misfits; each cycle's convergence probability drops while
regression risk rises. Especially true for rendering/scroll/layout/keyboard bugs.

### 6. Device-validation before merge
A green headless/widget test is a FALSE GREEN for device-class bugs (layout, keyboard inset,
scroll, lifecycle, gestures). Gate behavioral/UI changes on the emulator integration suite,
run red→green on-device, and let the owner confirm on hardware before merge. **Why:** #539,
#546, #547, #594, #595 all shipped "validated" on headless and broke on the device.

### 7. TDD-first
Write tests before code; verify they fail (red), then pass (green). For non-obvious specs use
the two-phase split: `/write-tests` defines behavior from the spec, then `/develop` implements
to green. A PR without test coverage for its change is not integration-ready. **Why:** an agent
that writes tests after code tests its own implementation, not the spec — that's circular.

### 8. Scope discipline
< 200 lines and ≤ 5 files per change. Minimal diffs; match existing patterns; no new
abstractions, helpers, or refactors beyond what the issue needs. Don't touch files outside
scope. **Why:** over-engineering and scope creep are the #1 bot failure mode; large diffs
aren't reviewable and their blast radius isn't containable.

### 9. Validate against REAL captured grids, not synthetic
For terminal/wrap/scroll/selection work, replay the owner's actual captured grids
(repro recordings, real tmux/scrollback), not hand-built synthetic states. **Why:** synthetic
tall surfaces with no keyboard inset hide the device-class bug you're chasing; validating a
fake state costs builds (the #666 first-connect-fill loop) and ships a false fix.

### 10. State via explicit lifecycle enum
Model session/feature lifecycle as one explicit enum with a single `transition(from, to)`,
not ad-hoc combinations of booleans (`connected && !wsOpen && wasConnected`). UI reads the
state directly. **Why:** boolean matrices produce order-dependent bugs, zombie states, and
conditions nobody can reason about; each new feature adds another flag and another matrix.

### 11. Monochrome theme icons, no emoji
UI icons are stylized, theme-compliant monochrome glyphs (Material Icons / `currentColor`
SVG). Never colorful emoji as UI icons; no emoji in code or UI text unless explicitly
requested. **Why:** emoji break the visual language and theme compliance; the keybar is one
line of touch-friendly monochrome glyphs.

### 12. Native is a UX duplicate of the refined PWA
The native app mirrors the refined PWA minus workaround noise. Reuse the PWA's existing
test/integration/acceptance infra (fixtures, review-server, appium, replay harness) — survey
it first; don't reinvent or redesign. A session = terminal + files with seamless movement
between them; terminal real estate is premium. **Why:** the PWA modules and screenshots ARE
the spec for every UX issue.

---

**Reversibility:** this is documentation. To retire an article, edit or delete it and bump
the version. Articles are durable principles, not transient task notes — those go in TRACE,
memory, or the issue.
