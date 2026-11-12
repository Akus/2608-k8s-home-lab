#!/usr/bin/env bash
# Run ad-hoc SQL against the lakehouse, as a one-shot Spark Job.
#
#   runbooks/lakehouse-sql.sh "SELECT * FROM lake.ops.node_samples LIMIT 5"
#   runbooks/lakehouse-sql.sh -f my-query.sql
#
# Each call is a fresh Spark pod, so expect ~60-90s even with the ivy cache warm. That is the
# cost of local[2] batch jobs rather than a long-lived SQL engine — fine for a lab, and the
# thing you would replace with a Thrift server or Trino if this were real.
source "$(dirname "$0")/lib.sh"

NS=lakehouse
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/clusters/home-lab/lakehouse/spark/spark-job.yaml"

if [[ "${1:-}" == "-f" ]]; then
    [[ -f "${2:-}" ]] || { echo "usage: $0 -f <file.sql>" >&2; exit 1; }
    SQL=$(cat "$2")
else
    SQL="${*:-}"
fi
[[ -n "$SQL" ]] || { echo "usage: $0 \"<SQL>\"  |  $0 -f <file.sql>" >&2; exit 1; }

JOB="lakehouse-sql-$(date +%s)"

kubectl -n $NS create configmap lakehouse-query \
    --from-literal=query.sql="$SQL" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

sed -e "s|__JOB__|${JOB}|g" -e "s|__SCRIPT__|sql.py|g" "$TEMPLATE" | kubectl apply -f - >/dev/null
echo "running $JOB ..."

for _ in $(seq 1 60); do
    POD=$(kubectl -n $NS get pod -l job-name="$JOB" -o name 2>/dev/null | head -1)
    [[ -n "$POD" ]] && break
    sleep 5
done
[[ -n "${POD:-}" ]] || { echo "pod never appeared" >&2; exit 1; }

# Only the script's own output matters; Spark's startup chatter goes to stderr.
kubectl -n $NS logs -f --ignore-errors "$POD" 2>/dev/null | grep -vE '^\s*$|WARN|INFO'

SUCCEEDED=$(kubectl -n $NS get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
kubectl -n $NS delete job "$JOB" --wait=false >/dev/null 2>&1 || true
[[ "${SUCCEEDED:-0}" == "1" ]] || { echo "query failed — see: kubectl -n $NS logs $POD" >&2; exit 1; }
