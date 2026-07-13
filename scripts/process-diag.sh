#!/usr/bin/env bash
# scripts/process-diag.sh — snapshot what's clogging the process table.
set -uo pipefail
echo "total: $(ps -u dev --no-headers -o pid= | wc -l)"
echo "top commands:"
ps -u dev --no-headers -o comm | sort | uniq -c | sort -rn | head -12
echo "sample of top offender args (first 3 distinct parents):"
TOP=$(ps -u dev --no-headers -o comm | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
echo "offender: $TOP"
ps -u dev --no-headers -o pid,ppid,etimes,args -C "$TOP" --sort=-etimes | head -6 | cut -c1-200
echo "parents of offender:"
for pp in $(ps -u dev --no-headers -o ppid -C "$TOP" | sort -u | head -5); do
  ps -p "$pp" -o pid,ppid,etimes,args --no-headers 2>/dev/null | cut -c1-200
done
