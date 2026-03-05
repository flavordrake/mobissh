# Workflow

## Inferred constraints
- **Never silently adopt an inferred constraint** that impacts architecture, language, or testability.
- If a constraint wasn't explicitly stated by the user, call it out prominently: "I'm assuming X, this affects Y and Z. Confirm?"
- When writing rules, mark inferred-but-impactful constraints with [INFERRED] so they get reviewed.

## Issue workflow
- `bug: <description>` in user messages = file a GitHub issue, do NOT fix immediately.
- Bot tasks: add a comment with `@claude` in the body so the Claude Code GitHub integration picks up the work.
- Process documentation in `.claude/process.md` defines label taxonomy, workflow states, delegation lifecycle.
- `bot` <> `divergence` lifecycle: delegate applies bot, integrate swaps to divergence on failure, delegate swaps back on re-delegation.
- `blocked` label always requires an explanatory comment. `conflict` is transient (resolve within one cycle).

## PR checklist
Before submitting a PR, run the full test suite:
```
scripts/test-typecheck.sh && scripts/test-lint.sh && scripts/test-unit.sh && scripts/test-headless.sh
```

## Know when to quit
- If a feature needs >2 fix cycles after initial implementation, pause and branch it off.
- Mobile UX features MUST be tested on real hardware before merging to main.
- If every fix introduces a new bug, the abstraction is wrong. Step back.
- Prefer contained changes; if a feature scatters guards across unrelated handlers, it's too coupled.

## After /clear
Read `.claude/skills/*/SKILL.md` descriptions and `.claude/agents/*.md` to re-establish awareness of available automation.
