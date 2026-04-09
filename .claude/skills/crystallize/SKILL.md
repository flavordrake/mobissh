---
name: crystallize
description: Use when the user says "crystallize", "compact", "compile", "distill", or asks to reduce a skill's reliance on LLM prose reasoning. Phase-transitions deterministic operations out of skill docs into real scripts with real test data. Rewrites the SKILL.md to be shorter and call the scripts instead of describing the logic. Aggressive about the boundary: LLM does judgment, prose, ambiguity resolution. Scripts do math, time comparison, parsing, counting, aggregation, schema validation.
license: Apache-2.0
---

# Crystallize

A skill is a recipe the LLM follows. Parts of that recipe involve real
judgment — UX tradeoffs, novel problem-solving, code quality, writing
clear prose for humans. Those parts must stay in LLM hands.

Other parts don't. Counting things, comparing timestamps, parsing
structured data, computing pass rates, sorting by number, aggregating
across files, validating schemas — these are deterministic operations.
An LLM asked to do them will be wrong sometimes, and the error mode is
usually silent.

`crystallize` finds those operations in a SKILL.md and **phase-transitions
them out**: the prose instruction becomes a real script with a real test
suite driven by real TRACE data, and the SKILL.md gets rewritten to
invoke the script. Net result: the skill is shorter, faster, and
correct-by-construction on the deterministic parts.

## The boundary

```
╭────────────────────────────────────────╮
│  LLM job (probabilistic, judgment)     │
├────────────────────────────────────────┤
│  • Intent disambiguation                │
│  • Code quality review                  │
│  • UX tradeoff decisions                │
│  • Novel problem-solving                │
│  • Writing human-facing prose           │
│  • Deciding WHICH script to call        │
│  • Interpreting script output           │
├────────────────────────────────────────┤
│  Script job (deterministic, scripted)  │
├────────────────────────────────────────┤
│  • Arithmetic / math / statistics       │
│  • Timestamp comparison, duration calc  │
│  • Counting files, lines, commits       │
│  • Sorting, ordering, ranking           │
│  • Parsing JSON/YAML/TOML/INI           │
│  • Regex on structured formats          │
│  • Aggregation and grouping             │
│  • Schema validation                    │
│  • Version/semver/hash comparison       │
│  • Structural diffs                     │
│  • Pattern matching (grep/glob)         │
│  • Cascading layered probes             │
╰────────────────────────────────────────╯
```

Every sentence in a SKILL.md that asks the LLM to do something in the
bottom box is a crystallization candidate.

## When to use

- A skill is getting long (>200 lines) and you suspect much of it is
  prose re-explaining computation the agent could just execute.
- A skill is producing inconsistent results across runs when given the
  same input — a sign the LLM is winging the deterministic parts.
- You just wrote a new skill and want a compaction pass before shipping.
- TRACE data from the skill shows the agent spending tokens narrating
  counts and comparisons instead of producing outputs.
- You explicitly ask: "crystallize", "compact", "compile", "distill".

## Inputs

Required:
- **target**: a skill name or glob (`integrate`, `*`, `delegate,develop`)

Optional:
- **trace-source**: directory of TRACE files to mine for real-world test
  data (default: `.traces/`). The skill pulls actual inputs the target
  skill saw in past runs and uses them as fixtures for the generated
  script tests.
- **dry-run**: don't write any files, just print the audit report.

## Phases

### Phase 1: Audit

Walk the target SKILL.md file(s) line by line. Classify each
instruction into one of three buckets:

- **A — already scripted**: the instruction invokes a shell script,
  wrapper, or tool (e.g. `scripts/gh-ops.sh`, `scripts/trace-init.sh`).
  Cite the file:line. These are the reference examples and don't need
  changes unless the script itself is broken.
- **B — should be scripted**: the instruction describes a deterministic
  operation in prose. Capture the operation's intent and inputs.
  Example signal phrases: "count the", "sort by", "within the last N",
  "parse the", "extract all", "compute the average", "compare".
- **C — must stay probabilistic**: the instruction asks for judgment,
  prose writing, or novel reasoning. One-line "why" each so future
  passes don't re-try to crystallize them.

Output this classification as a table per skill. This IS the audit
report — if `dry-run`, the skill stops here.

### Phase 2: Discover existing deterministic tools

**Runs BEFORE fixture mining and BEFORE drafting any new script.**
The highest-leverage finds are tools that already exist in the repo
but no skill knows about them — work that was done once, used once,
never advertised. Crystallizing those is free: zero new code, just
wiring.

Walk every directory that could hold a usable tool:

- `scripts/` — top-level intent-named scripts. Note the CLI shape from
  each header comment. Cross-reference: which scripts are invoked by
  some SKILL.md? Which are not?
- `scripts/lib/` — sourced helpers. Note any function with a clear
  single-purpose contract that could be wrapped in a CLI script.
- `tools/` — non-`scripts/` utility programs (review server, JSON
  parsers, frame extractors). Same audit.
- `.traces/*/artifacts/` — one-off scripts written inside a TRACE arc
  while solving a problem. **These are the highest-value finds:**
  someone built a deterministic tool to solve a real problem, used it
  once, and never promoted it. Promote it to `scripts/` if it has reuse.
- TRACE `logs/` and `strategy/pivot_*.md` — search for shell snippets
  the agent ran during the arc that should have been scripts. If a
  pivot says "we discovered we needed to compute X, so we ran <bash
  one-liner>", that one-liner is a candidate to formalize.

For every tool found, classify:

- **invoked** — at least one current SKILL.md or script calls it. Note
  which one(s).
- **orphaned** — nothing currently calls it, but the contract is clear
  and it solves a real problem. **High-value crystallization candidate.**
- **half-built** — started in a TRACE arc, abandoned or scoped to that
  arc only. Either promote or delete (don't leave undead).
- **dead** — contract unclear, no real use case, or duplicates a better
  tool. Mark for removal.

The output of this phase is a **tool registry** at
`.claude/tool-registry.md` (or appended to it on subsequent runs). The
registry is durable across crystallize passes and discoverable by every
other skill — it's the catalog of "deterministic tools available in
this repo, what they do, what they take, what they return".

**Then** cross-reference the tool registry with the B-bucket from
phase 1: for each operation that should be scripted, is there ALREADY
a tool that does it? If yes, skip the draft step entirely — go to
phase 5 and wire it up. This is the cheap-win path.

Rationale: rebuilding a tool that already exists is the worst possible
crystallize outcome. Worse than rewriting a SKILL.md to be longer,
worse than missing a B-bucket entry. The user's instruction was
explicit: prioritize finding tools that already emerged during
problem-solving, even if no instruction asks for them. Those are the
proof-of-need finds and they're already paid for.

### Phase 3: Mine TRACE data for fixtures

**Only runs for B-bucket operations that phase 2 did not find an
existing tool for.** This is the new-script path.

For each remaining B-bucket operation, walk `trace-source` and find
TRACEs where the target skill was actually invoked. Extract the inputs
the skill received (from `specs/`, `logs/`, `artifacts/`, TRACE.md
decisions section). These become the fixtures for the script's test
suite.

If no TRACE data exists for the operation, generate a minimal synthetic
fixture that covers the known edge cases (empty input, single item,
ordering, duplicates). Always mark synthetic fixtures clearly so a
later pass can replace them with real data.

**Rationale:** the whole point is to reduce LLM winging. Handcrafted
fixtures that happen to cover the happy path don't prove correctness —
real-world TRACE data does.

### Phase 4: Extract / draft script

For each B-bucket operation NOT covered by an existing tool from
phase 2:

1. Draft `scripts/<verb>-<noun>.sh` (or `.py` / `.js` if the operation
   needs structured-data libraries bash lacks). Use the existing
   scripts in this repo as the style reference — intent-named,
   `set -euo pipefail`, MOBISSH_TMPDIR convention, explicit flags.
2. The script's CLI must be stable and documented in its header. The
   SKILL.md will call it by name, so breaking the CLI breaks every
   dependent skill.
3. Add a test file adjacent to the script. Unit-test style: each known
   fixture from phase 3 → expected output. The test should fail loudly
   if the script's behavior drifts.
4. Register the new script in `.claude/tool-registry.md` so the next
   crystallize pass on a different skill finds it in phase 2.

**Keep scripts single-purpose.** Resist "while I'm here, let me also
handle X". One script per operation. Composition happens in the SKILL.md.

### Phase 5: Verify

Run the drafted script against every fixture. It must produce the
same output every run. If the output depends on wall-clock time, the
script must accept a `--now` flag or `SOURCE_DATE_EPOCH` env var so
tests can pin time.

If the fixture represents an operation that was previously done by an
LLM in a TRACE, compare the script's output to what the LLM actually
produced in that TRACE. They should match. If they don't:
- The script is wrong → fix it
- The LLM was wrong in the TRACE → this is the value proof; note it
  in the audit report under "LLM was inconsistent: replaced"

### Phase 6: Rewrite the SKILL.md

This is the compacting step. For every B-bucket operation now covered
by a script, replace the prose with a script invocation.

**Before:**
```markdown
### Step 3: Count how many bot attempts the issue has had

Look in `memory/bot-attempts.md` for entries matching the issue
number. Each entry is a heading like `## #N: <title>`. Count entries
under that heading that have a `status: fail` field. If the count
is 3 or more, do not re-delegate — file a comment on the issue
explaining the pattern of failures instead.
```

**After:**
```markdown
### Step 3: Count failed attempts

```
scripts/count-bot-attempts.sh <issue-number>
```

Output: `<count>` (integer). If >= 3, do not re-delegate — file a
comment on the issue explaining the failure pattern instead.
```

Rules for the rewrite:
- **Be ruthless.** If the LLM doesn't need the explanation to decide
  what to do next, delete it. Keep only what the LLM uses.
- **Keep the script invocation on its own fenced block.** The LLM
  needs to spot it visually and copy it into a tool call.
- **Document the output shape inline.** One sentence: what shape does
  the script return, and what does the LLM do with it?
- **Preserve the decision the LLM makes from the script output.** That
  IS the probabilistic part that belongs in the skill doc. The
  *computation* leaves, the *decision based on the computation* stays.
- **Remove section headings that no longer have content.** Compaction
  is literal: the final SKILL.md should be shorter than the input.

### Phase 7: Write the report

Append a block to the rewritten SKILL.md (or a sibling
`crystallize-report.md`) listing:
- Scripts extracted (name, fixtures used, line count)
- Scripts reused (name, file:line in SKILL.md that now calls it)
- LLM-inconsistency findings from phase 4, if any
- Operations that stayed probabilistic (with one-line why)

This report is the durable artifact. Future passes start from it.

## Invariants

- **Never delete prose that describes a probabilistic decision.** The
  boundary is sacred. If you're unsure whether something is judgment or
  computation, leave it in the SKILL.md and flag it in the C-bucket.
- **Never ship an extracted script without a test file.** The whole
  point is determinism — an untested script is just more prose.
- **Never break the CLI of an existing script you're invoking.** The
  SKILL.md compaction is a consumer; scripts are the contract. If a
  script needs a new flag, add it backward-compatibly.
- **Every script must be runnable from the project root with no setup.**
  No special env vars beyond `MOBISSH_TMPDIR`/`MOBISSH_LOGDIR`. If the
  script needs state, it creates it.
- **Don't crystallize a skill that's already short and obviously
  judgment-driven.** Compaction has a floor; don't invent deterministic
  operations to extract. `decompose` is a good example of a skill that
  should mostly stay probabilistic.

## What success looks like

After a crystallize pass on a target skill:
- The SKILL.md is shorter than before (often 30–60% reduction).
- Every arithmetic, counting, comparison, or parsing operation has moved
  out into a real script with a real test.
- The LLM's job in the skill is now *exclusively* judgment, prose,
  and deciding which script to call next based on structured output
  from the previous script.
- Re-running the skill on the same input produces the same tool calls
  for the deterministic parts — variance in the output is visible only
  in the probabilistic parts, where it belongs.

## Signals you should NOT crystallize a step

If a step has any of these properties, it probably belongs in the C
bucket (must stay probabilistic):

- It involves reading code and forming a quality opinion.
- It involves writing prose intended for a human to read.
- The correct output depends on prior conversation context the script
  wouldn't have access to.
- The operation requires natural language understanding of intent.
- The step is asking "should we do X?" not "what are the numbers?"
- Multiple valid outputs exist and the choice among them requires
  taste.

If you find yourself writing a 200-line script full of heuristics and
special cases to replace a one-paragraph LLM instruction, stop — that's
a sign the operation is actually probabilistic and the script is a
fragile attempt to simulate judgment. Revert and move the step to the
C bucket.

## Relationship to other skills

- **agent-trace**: provides the TRACE data that phase 2 mines for
  fixtures. A mature repo with many TRACEs can crystallize faster
  because fixtures are plentiful.
- **write-tests**: the test files phase 3 produces are unit tests,
  but they're handcrafted against fixtures — not the same as the
  behavioral tests `write-tests` produces for app code. Don't confuse.
- **simplify**: `simplify` reviews CHANGED code for cleanup; `crystallize`
  reviews SKILL DOCS for computational content that should move into
  scripts. Different targets, non-overlapping scope.
- **decompose**: decomposition is fundamentally judgment-driven —
  `crystallize` will leave it alone except for one small scripted piece
  (counting touched files, which is already scripted).

## Outcome goal

Push the LLM toward a workflow where every single tool call is either
(a) a deterministic script that takes structured input and produces
structured output, or (b) a prose response that makes a judgment based
on the structured output of prior scripts. The LLM never does math.
The LLM never counts. The LLM never compares timestamps. The LLM never
parses a format it could invoke a parser for. Those are script jobs,
and crystallize is the pass that finds them and makes them so.
