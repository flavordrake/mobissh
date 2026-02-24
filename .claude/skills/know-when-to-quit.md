# Skill: Know When to Quit

## Purpose
Recognize when iterative fixes to a feature are diverging rather than converging, and act on that recognition before the cost compounds further.

## The Core Question
After each fix, ask: **"Is this fix making the code simpler and more correct, or is it adding complexity to compensate for the previous fix?"**

If the answer is the latter for two consecutive fixes, you are patching around a structural problem. More patches will not fix a structural problem.

## Trigger Signals
Stop and reassess when you observe any two of the following:

1. **Fix count exceeds budget.** More than 2 fix cycles after initial implementation without a stable result. Each cycle that doesn't reach stability makes the next cycle less likely to.
2. **Each fix introduces a new, previously-unseen failure mode.** The bug isn't being narrowed; it's migrating. This means the approach has a structural misfit with its environment.
3. **Fixes scatter guards into unrelated code.** When you're adding `if (featureActive)` checks in modules that shouldn't know your feature exists, the abstraction boundary has failed.
4. **Same class of bug appears twice.** Two scoping errors, two race conditions, two layout drift bugs — this is a pattern, not a coincidence. The code shape is incompatible with the problem.
5. **Can't validate on the target platform during development.** If you're fixing mobile UX bugs using only headless tests, your iteration loop is: push, test on device, find new bug, fix blind, repeat. This loop does not converge.
6. **Expert review finds more issues than fix cycles have addressed.** If a review after N fixes surfaces N+1 new problems, you are falling behind, not catching up.

## Decision Framework

### Flag off
Use when: the code is self-contained, you expect to revisit it soon, and the dead code doesn't add risk or confusion. Acceptable as a short-term holding state, not a permanent one.

### Clean revert
Use when: the dead code is polluting the main branch, there's no clear timeline for revival, or the flagged-off code has tendrils in unrelated modules (event handlers, lifecycle hooks, layout). Revert to the last known good commit.

### Branch and delegate
Use when: the work has value but needs a fundamentally different approach or more focused attention. Preserve the code on a named branch, document what was learned, and file an issue describing the new approach. Someone (or future-you) picks it up fresh without the accumulated patches.

## What to Preserve
When rolling back, do not throw away the learning:
- **The case study.** Document what went wrong and which signals appeared, so the pattern is recognizable next time.
- **Expert reviews.** Any analysis of the broken code describes real constraints the next attempt must satisfy.
- **Issue documentation.** Update the issue with the approach that failed, why it failed, and what a better approach might look like.
- **The branch.** Keep the experimental code accessible. It's a reference, not a starting point.

## The Sunk Cost Dimension
The hardest part of this skill is not the analysis — it's the decision. After multiple fix cycles you have invested time, written commit messages explaining the work, and mentally framed the feature as "almost done." The instinct is to try one more fix.

But the economics are clear: each fix cycle costs roughly the same amount of effort, while the probability of convergence drops and the risk of breaking unrelated functionality rises. The total cost of "one more fix" includes the fix itself, the regression it may cause, and the next fix after that. Stopping early is not admitting failure — it is recognizing that a different approach will succeed where this one cannot.

## Case Study: Selection Overlay (MobiSSH #55/#108/#111)
A transparent-text-over-canvas overlay for mobile text selection went through 5 fix cycles. Each fix resolved one bug and introduced another: positioning drift, stale DOM, keyboard/resize cascade, scoping errors. Fixes leaked into resize handlers and focus management. Two separate TDZ errors indicated structural scope problems. The feature was never usable on real hardware despite passing headless tests. After an expert review found 5 P1 issues in code that had been through 4 fix cycles, the feature was flagged off, then branched for a fresh approach.

Every signal listed above was present by fix 3. The rollback should have happened two cycles earlier.
