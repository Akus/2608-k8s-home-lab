#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

check "catalog is reachable on 127.0.0.1:8181" bash -c "curl -s -m 5 -o /dev/null http://127.0.0.1:8181/v1/config"
check "object storage is reachable on 127.0.0.1:3900" bash -c "ss -ltn 2>/dev/null | grep -q ':3900 '"

NS_JSON=$(curl -s -m 5 http://127.0.0.1:8181/v1/namespaces 2>/dev/null || true)
check "catalog exposes the ops namespace" bash -c "grep -q '\"ops\"' <<<'$NS_JSON'"

TBL=$(curl -s -m 5 http://127.0.0.1:8181/v1/namespaces/ops/tables 2>/dev/null || true)
for t in node_samples weather node_hourly; do
  check "catalog lists lake.ops.$t" bash -c "grep -q '\"$t\"' <<<'$TBL'"
done

# The real proof: a client actually reading data files out of object storage.
DUCK=$(command -v duckdb || echo "")
if [[ -z "$DUCK" ]]; then
  echo "  SKIP duckdb not on PATH in WSL — if you connected from Windows, check there instead:"
  echo "       SELECT count(*) FROM lake.ops.node_samples;   (expect a number, not an error)"
else
  if [[ ! -f "$HERE/init.local.sql" ]]; then
    fail "init.local.sql missing — run ./setup.sh"
  else
    OUT=$("$DUCK" -init "$HERE/init.local.sql" -noheader -list \
            -c "SELECT count(*) FROM lake.ops.node_samples;" 2>&1 | tail -1)
    if [[ "$OUT" =~ ^[0-9]+$ ]] && (( OUT > 0 )); then
      pass "duckdb read $OUT rows from lake.ops.node_samples"
    else
      fail "duckdb could not read the table (got: ${OUT:0:90})"
    fi
  fi
fi

summary
