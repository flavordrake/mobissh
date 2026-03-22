# MobiSSH Workflow

## Issue workflow
- Process documentation in `.claude/process.md` defines label taxonomy, workflow states, delegation lifecycle.
- `bot` <> `divergence` lifecycle: delegate applies bot, integrate swaps to divergence on failure, delegate swaps back on re-delegation.
- `blocked` label always requires an explanatory comment. `conflict` is transient (resolve within one cycle).

## PR checklist
Before submitting a PR, run the full test suite:
```
scripts/test-fast-gate.sh
scripts/test-headless.sh
```

## Device testing
- Mobile UX features MUST be tested on real hardware before merging to main.
