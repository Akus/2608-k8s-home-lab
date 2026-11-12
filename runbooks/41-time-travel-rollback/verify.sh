#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

OUT=$("$ROOT/runbooks/lakehouse-sql.sh" "
SELECT concat_ws(' ', 'RBSTATS',
  CAST((SELECT COUNT(*) FROM lake.ops.node_samples WHERE temp_c > 200) AS STRING),
  CAST((SELECT COUNT(*) FROM lake.ops.node_samples) AS STRING),
  CAST((SELECT COUNT(*) FROM lake.ops.node_samples.snapshots) AS STRING))" 2>&1)

read -r _ BAD TOTAL SNAPS <<<"$(grep -oE 'RBSTATS [0-9]+ [0-9]+ [0-9]+' <<<"$OUT" | head -1)"
if [[ -z "${BAD:-}" ]]; then fail "could not query the table"; summary; fi

echo "impossible_rows=$BAD total_rows=$TOTAL snapshots=$SNAPS"
check_eq "no rows above 200 C remain"              "0" "$BAD"
check "the good rows are still there"              test "$TOTAL" -gt 0
check "history was preserved, not truncated"       test "$SNAPS" -ge 2
summary
