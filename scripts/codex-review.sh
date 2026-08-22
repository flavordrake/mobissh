#!/usr/bin/env bash
# scripts/codex-review.sh — run a non-interactive codex review over a prompt file.
#
# Captures the hand-wired `codex exec` invocation that has been mistyped before
# (an earlier bad relative path fed codex an EMPTY prompt and produced a
# confident review of nothing). Guards: prompt file must exist and be non-empty;
# output must be non-empty or we exit non-zero and say NO REVIEW PERFORMED.
#
# Usage: scripts/codex-review.sh PROMPT_FILE OUT_FILE [MODEL]
#   MODEL defaults to gpt-5.6-sol.

set -euo pipefail
cd "$(dirname "$0")/.."

MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_LOGDIR"
LOGFILE="${MOBISSH_LOGDIR}/codex-review.log"
exec > >(tee -a "$LOGFILE") 2>&1

PROMPT_FILE="${1:?usage: codex-review.sh PROMPT_FILE OUT_FILE [MODEL]}"
OUT_FILE="${2:?usage: codex-review.sh PROMPT_FILE OUT_FILE [MODEL]}"
MODEL="${3:-gpt-5.6-sol}"

if [[ ! -s "$PROMPT_FILE" ]]; then
  echo "! prompt file missing or empty: $PROMPT_FILE — NO REVIEW PERFORMED"
  exit 2
fi

echo "> codex review: model=$MODEL prompt=$PROMPT_FILE ($(wc -c < "$PROMPT_FILE") bytes)"
if ! codex exec --model "$MODEL" --sandbox read-only -o "$OUT_FILE" "$(cat "$PROMPT_FILE")"; then
  echo "! codex exec failed — NO REVIEW PERFORMED"
  exit 3
fi

if [[ ! -s "$OUT_FILE" ]]; then
  echo "! codex produced an empty answer: $OUT_FILE — NO REVIEW PERFORMED"
  exit 4
fi

echo "+ review written: $OUT_FILE ($(wc -c < "$OUT_FILE") bytes)"
