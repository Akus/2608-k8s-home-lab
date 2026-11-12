#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# concat_ws gives one unambiguous token to parse, instead of scraping Spark's table borders
OUT=$("$ROOT/runbooks/lakehouse-sql.sh" "
SELECT concat_ws(' ', 'RBSTATS',
  CAST((SELECT COUNT(*) FROM lake.ops.node_samples)           AS STRING),
  CAST((SELECT COUNT(*) FROM lake.ops.node_samples.files)     AS STRING),
  CAST((SELECT COUNT(*) FROM lake.ops.node_samples.snapshots) AS STRING))" 2>/dev/null)

read -r _ ROWS FILES SNAPS <<<"$(grep -oE 'RBSTATS [0-9]+ [0-9]+ [0-9]+' <<<"$OUT" | head -1)"

if [[ -z "${ROWS:-}" ]]; then
  fail "could not read table stats (is the lakehouse up? kubectl -n lakehouse get pods)"
  summary
fi

echo "rows=$ROWS data_files=$FILES snapshots=$SNAPS"
check "the table still has rows (nothing was lost)" test "$ROWS" -gt 0
check "data files were compacted (fewer than 10)"   test "$FILES" -lt 10
check "snapshots were expired (25 or fewer kept)"   test "$SNAPS" -le 25
check "at least 10 snapshots of history remain"     test "$SNAPS" -ge 10
summary
