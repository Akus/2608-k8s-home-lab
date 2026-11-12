#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT/runbooks/lakehouse-sql.sh" "DROP TABLE IF EXISTS lake.dev.pod_counts" >/dev/null 2>&1 || true
"$ROOT/runbooks/lakehouse-sql.sh" "DROP NAMESPACE IF EXISTS lake.dev" >/dev/null 2>&1 || true
kubectl -n lakehouse get job -o name 2>/dev/null | grep -E 'rb42' | xargs -r kubectl -n lakehouse delete >/dev/null 2>&1 || true
echo "lake.dev dropped. Your files are still in git — revert with:"
echo "  git checkout clusters/home-lab/lakehouse clusters/home-lab/jenkins"
echo "  rm -f clusters/home-lab/lakehouse/spark/ingest_pods.py"
