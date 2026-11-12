#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

OUT=$("$ROOT/runbooks/lakehouse-sql.sh" "
SELECT concat_ws(' ', 'RBSTATS',
  CAST((SELECT COUNT(*) FROM lake.ops.node_samples) AS STRING),
  CAST((SELECT COUNT(*) FROM lake.ops.node_samples WHERE swap_bytes IS NOT NULL) AS STRING),
  CAST((SELECT COUNT(*) FROM lake.ops.node_samples WHERE swap_bytes IS NULL) AS STRING))" 2>&1)

if ! grep -q RBSTATS <<<"$OUT"; then
  fail "swap_bytes does not exist yet (the query failed to resolve the column)"
  summary
fi
read -r _ TOTAL WITH WITHOUT <<<"$(grep -oE 'RBSTATS [0-9]+ [0-9]+ [0-9]+' <<<"$OUT" | head -1)"

echo "total=$TOTAL with_swap=$WITH without_swap=$WITHOUT"
check "the swap_bytes column exists and is queryable" test -n "$TOTAL"
check "pre-existing rows survived"                    test "$TOTAL" -gt 0
check "at least one new row has swap_bytes populated" test "$WITH" -ge 1
check "old rows read back as NULL, not as an error"   test "$WITHOUT" -ge 1
summary
