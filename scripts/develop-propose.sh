#!/usr/bin/env bash
# scripts/develop-propose.sh — Propose bot-labeled issues for development
#
# Reads open issues labeled `bot`, scores by risk and relevance to recent work,
# and outputs a ranked JSON array for the /develop skill to present.
#
# Usage: scripts/develop-propose.sh [--theme THEME] [--max N]
#   --theme   Keywords describing current work focus (e.g., "ime notifications upload")
#   --max     Maximum proposals to return (default: 5)
#
# Output (stdout): JSON array of proposals, sorted by score (highest first):
#   [{ "number": 125, "title": "...", "labels": [...], "risk": "low|medium|high",
#      "relevance": 0-100, "score": 0-100, "reason": "..." }]
#
# Scoring:
#   base      = 50
#   +20       if risk is "low" (single file, <100 lines expected)
#   +10       if risk is "medium"
#   -10       if risk is "high" (server, vault, crypto, multi-module)
#   +30       if title/labels match --theme keywords
#   +15       if title/labels partially match (1+ keyword)
#   -20       if labeled "blocked"
#   -10       if labeled "device" (needs emulator, slower feedback)
#   +10       if labeled "bot" and no prior attempts (fresh delegation)
#   -15       if has bot/ branch (prior attempt exists)

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

THEME=""
MAX=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --theme) THEME="$2"; shift 2 ;;
    --max)   MAX="$2"; shift 2 ;;
    *)       echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Fetch open issues with bot label
ISSUES_JSON=$(gh issue list --label bot --state open --json number,title,labels,body --limit 50 2>/dev/null || echo "[]")

# Fetch bot branches to detect prior attempts
BOT_BRANCHES=$(git branch -r 2>/dev/null | grep 'origin/bot/issue-' | sed 's|.*origin/bot/issue-||' | tr '\n' ',' || echo "")

# Fetch recent git log to detect current work theme if --theme not provided
if [[ -z "$THEME" ]]; then
  THEME=$(git log --oneline -10 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
fi

# Score and rank with node
node -e "
const issues = JSON.parse(process.argv[1]);
const botBranches = process.argv[2].split(',').filter(Boolean);
const theme = process.argv[3].toLowerCase().split(/[\s,]+/).filter(Boolean);
const max = parseInt(process.argv[4]) || 5;

const HIGH_RISK_KEYWORDS = ['server', 'vault', 'crypto', 'security', 'encrypt', 'credential', 'ssh2', 'ws:', 'websocket'];
const DEVICE_LABELS = ['device', 'touch', 'ios'];

const proposals = issues.map(issue => {
  const labels = issue.labels.map(l => l.name);
  const titleLower = issue.title.toLowerCase();
  const bodyLower = (issue.body || '').toLowerCase().slice(0, 500);
  const combined = titleLower + ' ' + labels.join(' ') + ' ' + bodyLower;

  // Risk assessment
  let risk = 'medium';
  const isHighRisk = HIGH_RISK_KEYWORDS.some(k => combined.includes(k));
  const bodyLines = (issue.body || '').split('\n').length;
  const filesMentioned = (issue.body || '').match(/\x60[^\x60]+\.(ts|js|css)\x60/g) || [];
  if (isHighRisk || filesMentioned.length > 5) risk = 'high';
  else if (filesMentioned.length <= 2 && bodyLines < 40) risk = 'low';

  // Base score
  let score = 50;
  let reasons = [];

  // Risk modifier
  if (risk === 'low')    { score += 20; reasons.push('low risk'); }
  if (risk === 'medium') { score += 10; }
  if (risk === 'high')   { score -= 10; reasons.push('high risk'); }

  // Theme relevance
  const themeMatches = theme.filter(k => k.length > 2 && combined.includes(k));
  if (themeMatches.length >= 3) { score += 30; reasons.push('strong theme match: ' + themeMatches.slice(0,3).join(', ')); }
  else if (themeMatches.length >= 1) { score += 15; reasons.push('partial theme match: ' + themeMatches.join(', ')); }

  // Label modifiers
  if (labels.includes('blocked')) { score -= 20; reasons.push('blocked'); }
  if (DEVICE_LABELS.some(l => labels.includes(l))) { score -= 10; reasons.push('needs device'); }

  // Prior attempts
  const hasPriorAttempt = botBranches.includes(String(issue.number));
  if (hasPriorAttempt) { score -= 15; reasons.push('prior attempt exists'); }
  else { score += 10; reasons.push('fresh'); }

  // Clamp
  score = Math.max(0, Math.min(100, score));

  return {
    number: issue.number,
    title: issue.title,
    labels: labels,
    risk,
    relevance: themeMatches.length >= 3 ? 100 : themeMatches.length >= 1 ? 50 : 0,
    score,
    reason: reasons.join('; ')
  };
}).sort((a, b) => b.score - a.score).slice(0, max);

console.log(JSON.stringify(proposals, null, 2));
" "$ISSUES_JSON" "$BOT_BRANCHES" "$THEME" "$MAX"
