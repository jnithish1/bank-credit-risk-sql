#!/usr/bin/env bash
# =============================================================================
# run_analysis.sh - runs every business query in sql/06_analysis and saves
# the result of each as results/<query>.csv (committed, so reviewers can read
# the outputs on GitHub without running anything).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/results}"
export PGDATABASE="${PGDATABASE:-berka}"
mkdir -p "$OUT"

for f in "$ROOT"/sql/06_analysis/q*.sql; do
    name="$(basename "$f" .sql)"
    start=$(date +%s%N)
    psql -X -q -v ON_ERROR_STOP=1 --csv -f "$f" > "$OUT/$name.csv"
    rows=$(( $(wc -l < "$OUT/$name.csv") - 1 ))
    ms=$(( ($(date +%s%N) - start) / 1000000 ))
    printf '%-32s %6d rows  %6d ms\n' "$name" "$rows" "$ms"
done
