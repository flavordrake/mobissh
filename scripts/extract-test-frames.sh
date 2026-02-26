#!/usr/bin/env bash
# scripts/extract-test-frames.sh
#
# Extracts video frames from the emulator screen recording at moments that
# correspond to test execution. Lets an AI or human reviewer see exactly what
# was on screen when a test started, failed, or ended.
#
# Reads:
#   <results>/report.json   — Playwright JSON reporter output
#   <results>/recording.mp4 — adb screenrecord capture
#
# Writes:
#   <results>/frames/       — one PNG per extracted moment
#
# Usage:
#   bash scripts/extract-test-frames.sh                                # all tests
#   bash scripts/extract-test-frames.sh --failed                       # only failed tests
#   bash scripts/extract-test-frames.sh --results test-results/emulator # custom dir
#   bash scripts/extract-test-frames.sh --test "vault"                  # tests matching pattern

set -euo pipefail

RESULTS_DIR="test-results/emulator"

log() { printf '\033[36m> %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
err() { printf '\033[31m! %s\033[0m\n' "$*" >&2; exit 1; }

# Parse args
FILTER_FAILED=false
FILTER_PATTERN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --failed)  FILTER_FAILED=true; shift ;;
    --test)    FILTER_PATTERN="$2"; shift 2 ;;
    --results) RESULTS_DIR="$2"; shift 2 ;;
    *)         err "Unknown arg: $1. Usage: $0 [--failed] [--test pattern] [--results dir]" ;;
  esac
done

REPORT="$RESULTS_DIR/report.json"
VIDEO="$RESULTS_DIR/recording.mp4"
FRAMES="$RESULTS_DIR/frames"

command -v ffmpeg &>/dev/null || err "ffmpeg not found. Install: sudo apt install ffmpeg"
command -v jq &>/dev/null || err "jq not found. Install: sudo apt install jq"
[[ -f "$REPORT" ]] || err "Report not found: $REPORT. Run emulator tests first."
[[ -f "$VIDEO" ]] || err "Recording not found: $VIDEO. Run emulator tests first."

# Get recording start time from the video file creation metadata.
# The screenrecord starts just before Playwright runs, so the first test's
# startTime minus a small offset gives us the video epoch.
# stats.startTime is when Playwright started the run — close to when screenrecord began.
FIRST_TEST_MS=$(jq -r '.stats.startTime | sub("\\.[0-9]+Z$"; "Z") | fromdate' "$REPORT" 2>/dev/null || echo "0")

if [[ "$FIRST_TEST_MS" == "0" || "$FIRST_TEST_MS" == "null" ]]; then
  err "Could not determine test start time from report."
fi

log "Reference time (first test): $(date -d "@$FIRST_TEST_MS" '+%H:%M:%S' 2>/dev/null || echo "$FIRST_TEST_MS")"

# Video duration in seconds
VIDEO_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VIDEO" | cut -d. -f1)
log "Video duration: ${VIDEO_DURATION}s"

# Clean and recreate frames dir
rm -rf "$FRAMES"
mkdir -p "$FRAMES"

# Extract test data: title, status, startTime (epoch seconds), duration (ms)
# The JSON reporter nests: suites > specs (has title, tests[]) > tests[] > results[]
TESTS_JSON=$(jq -r '
  [.. | objects | select(.tests? and .title?) |
    . as $spec |
    $spec.tests[] |
    {
      title: $spec.title,
      file: ($spec.file // "unknown"),
      results: [.results[] | {
        status: .status,
        startTime: (.startTime | sub("\\.[0-9]+Z$"; "Z") | fromdate),
        duration: .duration
      }]
    }
  ] | .[]' "$REPORT" 2>/dev/null) || true

if [[ -z "$TESTS_JSON" ]]; then
  err "Could not parse test results from report."
fi

FRAME_COUNT=0
BUFFER_BEFORE=2  # seconds before test start to capture

# Process each test
echo "$TESTS_JSON" | jq -c '.' | while IFS= read -r test_line; do
  TITLE=$(echo "$test_line" | jq -r '.title')
  FILE=$(echo "$test_line" | jq -r '.file' | sed 's|.*/||; s|\.spec\.js||')

  # Apply filters
  if [[ "$FILTER_FAILED" == "true" ]]; then
    HAS_FAILURE=$(echo "$test_line" | jq '[.results[] | select(.status != "passed" and .status != "skipped")] | length > 0')
    [[ "$HAS_FAILURE" == "true" ]] || continue
  fi
  if [[ -n "$FILTER_PATTERN" ]]; then
    echo "$TITLE" | grep -qi "$FILTER_PATTERN" || continue
  fi

  # Process each result (usually 1, more if retried)
  echo "$test_line" | jq -c '.results[]' | while IFS= read -r result_line; do
    STATUS=$(echo "$result_line" | jq -r '.status')
    START_EPOCH=$(echo "$result_line" | jq -r '.startTime')
    DURATION_MS=$(echo "$result_line" | jq -r '.duration')

    # Calculate video offsets
    OFFSET_START=$(( START_EPOCH - FIRST_TEST_MS ))
    OFFSET_END=$(( OFFSET_START + DURATION_MS / 1000 ))

    # Clamp to video bounds
    (( OFFSET_START < 0 )) && OFFSET_START=0
    (( OFFSET_END > VIDEO_DURATION )) && OFFSET_END=$VIDEO_DURATION

    # Sanitize title for filename
    SAFE_TITLE=$(echo "$TITLE" | tr -cs 'a-zA-Z0-9_-' '-' | head -c 60 | sed 's/-$//')
    PREFIX="${FILE}-${SAFE_TITLE}"

    # Extract frames at key moments
    # 1. Just before test starts (context: what was on screen)
    PRE_START=$(( OFFSET_START > BUFFER_BEFORE ? OFFSET_START - BUFFER_BEFORE : 0 ))
    ffmpeg -y -ss "$PRE_START" -i "$VIDEO" -frames:v 1 -q:v 2 \
      "$FRAMES/${PREFIX}-0-before.png" 2>/dev/null && FRAME_COUNT=$((FRAME_COUNT + 1)) || true

    # 2. Test midpoint (where the interesting action happens)
    MIDPOINT=$(( OFFSET_START + (OFFSET_END - OFFSET_START) / 2 ))
    ffmpeg -y -ss "$MIDPOINT" -i "$VIDEO" -frames:v 1 -q:v 2 \
      "$FRAMES/${PREFIX}-1-midpoint.png" 2>/dev/null && FRAME_COUNT=$((FRAME_COUNT + 1)) || true

    # 3. Just before test ends (failure or success moment)
    END_MINUS=$(( OFFSET_END > 1 ? OFFSET_END - 1 : OFFSET_END ))
    ffmpeg -y -ss "$END_MINUS" -i "$VIDEO" -frames:v 1 -q:v 2 \
      "$FRAMES/${PREFIX}-2-end-${STATUS}.png" 2>/dev/null && FRAME_COUNT=$((FRAME_COUNT + 1)) || true

    # 4. For failed tests: extract additional frames around the failure
    if [[ "$STATUS" != "passed" && "$STATUS" != "skipped" ]]; then
      # Quarter points for more granularity on failures
      Q1=$(( OFFSET_START + (OFFSET_END - OFFSET_START) / 4 ))
      Q3=$(( OFFSET_START + 3 * (OFFSET_END - OFFSET_START) / 4 ))
      ffmpeg -y -ss "$Q1" -i "$VIDEO" -frames:v 1 -q:v 2 \
        "$FRAMES/${PREFIX}-1a-quarter.png" 2>/dev/null || true
      ffmpeg -y -ss "$Q3" -i "$VIDEO" -frames:v 1 -q:v 2 \
        "$FRAMES/${PREFIX}-1b-threequarter.png" 2>/dev/null || true
    fi

    printf '  %-8s %3ds  %s\n' "[$STATUS]" "$((DURATION_MS / 1000))" "$TITLE"
  done
done

TOTAL=$(find "$FRAMES" -name "*.png" 2>/dev/null | wc -l)
ok "Extracted $TOTAL frames to $FRAMES/"
log "Review: ls $FRAMES/ or open individual PNGs"
