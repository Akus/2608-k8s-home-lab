#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT/runbooks/lakehouse-sql.sh" \
  "ALTER TABLE lake.ops.node_samples DROP COLUMN swap_bytes" >/dev/null 2>&1 \
  && echo "swap_bytes dropped (again, metadata only)." \
  || echo "Nothing to drop."
echo "If you edited ingest_samples.py, revert it with: git checkout clusters/home-lab/lakehouse/spark/ingest_samples.py && kubectl apply -k clusters/home-lab/lakehouse"
