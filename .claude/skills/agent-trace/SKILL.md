---
name: agent-trace
description: Protocol for capturing a complete development arc (TRACE). Includes telemetry, strategy pivots, logs, and performance metadata. Use this to record the "how and why" of an objective, especially for performance-critical or non-deterministic tasks.
license: Apache-2.0
metadata:
  version: "1.0.0"
  purpose: AI-Training-Data-Generation
---

# Agent TRACE (Trajectory & Runtime Artifact Collection Environment)

The `agent-trace` skill transforms a standard execution into a **Software Artifact Corpus**.
It captures not just the final code, but the "Mechanical Sympathy" between the agent's
intent, the hardware's response (telemetry), and the resulting strategy shifts.

## 1. Directory Structure

When this skill is activated, the agent MUST initialize the following structure in a
unique directory named `trace-[objective-slug]-[timestamp]/`:

```text
trace-dir/
├── TRACE.md           # Executive summary, metadata, and final outcomes
├── specs/             # Original requirements and identified ambiguities
├── strategy/          # Log of hypotheses and pivots (The "Decision Chain")
├── logs/              # Agent reasoning logs and build/compiler output
├── telemetry/         # NCU/NSYS reports, profiling data, or runtime traces
└── artifacts/         # Success/Failure code snapshots and sanitizer reports
```

## 2. The TRACE.md Specification

The `TRACE.md` file is the entry point for the "Harvesting Agent." It must include
multidimensional cost data.

### Frontmatter Template

```yaml
id: [unique-id]
objective: [high-level-goal]
status: [success | failure | partial]
skills-used: [list-of-skills]
resources:
  tokens: [total-token-count]
  compute_footprint:
    cpu_time: [format: 00m:00s]
    gpu_time: [format: 00m:00s]
metrics:
  target: [e.g., 900 TFLOPS]
  achieved: [actual-result]
```

## 3. Instructions for Agents

### Step 1: Initial Hypothesis

Before writing code, record the Initial Strategy in `strategy/initial_plan.md`.
Define tiling sizes, register budgets, and memory alignment expectations.
For non-HPC tasks: document the approach, expected file changes, test strategy,
and any assumptions about existing code behavior.

### Step 2: Telemetry Ingestion

If the task is performance-critical (e.g., CUDA/HPC), the agent MUST run profiling
tools (Nsight Compute, Systems, or Sanitizers). Save the raw output to `telemetry/`
and a summary of the bottleneck to `logs/`.

For web/PWA tasks: capture browser performance traces, network waterfall data,
transfer throughput measurements, or xterm.js rendering metrics.

### Step 3: The Pivot (The Delta)

Whenever the telemetry contradicts the hypothesis:

1. Create `strategy/pivot_N.md`
2. Document the **Triggering Evidence** (e.g., "High Register Pressure",
   "ack-wait 85% of upload time", "59 headless test failures")
3. Document the **Structural Change** (e.g., "Reduced Block Size",
   "batched terminal writes per rAF", "reverted preview-OFF hide")
4. **Quantify the Delta** in performance or correctness

### Step 4: Final Summarization (The Learning Step)

The final act of a TRACE agent is to populate the body of `TRACE.md` with:

- **The "Why"**: A post-mortem on why the final strategy succeeded or failed.
- **The "Ambiguity Gap"**: How specs were clarified during execution.
  What was assumed vs. what was explicitly stated. What the user corrected.
- **The "Knowledge Seed"**: A one-sentence heuristic for future agents
  (e.g., "On sm_90, favor TMA over manual SMem loads for 10% gain",
  "Never bump localStorage keys — migrate the value schema instead",
  "touchstart preventDefault on a scroll container blocks horizontal scroll").

## 4. Embedded Logic (For Non-Skill Agents)

If you are an agent without a filesystem-tooling layer, you must output your
response in a `[TRACE_SNAPSHOT]` block containing the YAML and Markdown
structures defined above so a supervisor can persist them.

```
[TRACE_SNAPSHOT]
id: trace-keybar-scroll-20260321
objective: Fix keybar scroll vs tap disambiguation
status: partial
...
[/TRACE_SNAPSHOT]
```

## 5. Integration with MobiSSH SDLC

### Where TRACEs live

```text
test-history/traces/
├── trace-sftp-upload-20260316/
├── trace-preview-countdown-20260315/
├── trace-keybar-scroll-20260321/
└── ...
```

`test-history/` is gitignored — TRACEs are local development artifacts,
not committed to the repo. They inform memory updates and process improvements.

### When to generate a TRACE

- **Always**: for performance-critical work (upload throughput, terminal rendering,
  network resilience)
- **On pivot**: when a strategy changes significantly mid-execution
- **On failure**: when an agent aborts — the TRACE documents why and what was tried
- **On request**: `/trace` generates a TRACE for the current or most recent work

### Harvesting: TRACE → Memory

After a TRACE is complete, the orchestrator (main session) extracts:

1. **Knowledge Seeds** → project memory (`feedback_*.md`)
2. **Process improvements** → skill/rule updates
3. **Heuristics** → `.claude/rules/` scoped files
4. **Bug patterns** → issue filing

This is the feedback loop: agents generate TRACEs → orchestrator harvests insights →
future agents benefit from accumulated knowledge.

## 6. Scripts and Tools

### scripts/trace-init.sh

Initialize a new TRACE directory with boilerplate:

```bash
scripts/trace-init.sh "objective-slug"
# Creates: test-history/traces/trace-{slug}-{timestamp}/
# With: TRACE.md, specs/, strategy/, logs/, telemetry/, artifacts/
```

### scripts/trace-validate.sh

Validate that a TRACE is complete:

- `TRACE.md` has frontmatter with status
- `strategy/initial_plan.md` exists
- If pivots exist, each has triggering evidence and delta
- If telemetry exists, it has corresponding strategy references

## Outcome Goal

Every TRACE directory should be a self-contained training sample for a
"Performance Architect" or "Software Intelligence" model. The combination of
intent (specs), strategy (hypotheses + pivots), evidence (telemetry), and
outcome (artifacts + TRACE.md) creates a complete decision trajectory that
captures not just *what* was done but *why* each choice was made.
