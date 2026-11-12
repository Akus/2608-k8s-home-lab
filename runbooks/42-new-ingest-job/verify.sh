#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

check "ingest_pods.py exists" test -f "$ROOT/clusters/home-lab/lakehouse/spark/ingest_pods.py"
check "it is listed in the configMapGenerator" grep -q 'ingest_pods.py' "$ROOT/clusters/home-lab/lakehouse/spark/kustomization.yaml"
check "it was deployed into the ConfigMap" bash -c "kubectl -n lakehouse get cm spark-scripts -o jsonpath='{.data}' 2>/dev/null | grep -q ingest_pods"
check "the spark ServiceAccount may list pods" bash -c "kubectl auth can-i list pods --as=system:serviceaccount:lakehouse:spark -A 2>/dev/null | grep -q yes"

OUT=$("$ROOT/runbooks/lakehouse-sql.sh" "
SELECT concat_ws(' ', 'RBSTATS',
  CAST((SELECT COUNT(*) FROM lake.dev.pod_counts) AS STRING),
  CAST((SELECT COUNT(DISTINCT namespace) FROM lake.dev.pod_counts) AS STRING))" 2>&1)
read -r _ ROWS NSCOUNT <<<"$(grep -oE 'RBSTATS [0-9]+ [0-9]+' <<<"$OUT" | head -1)"

if [[ -z "${ROWS:-}" ]]; then
  fail "lake.dev.pod_counts does not exist or is not queryable"
else
  echo "rows=$ROWS distinct_namespaces=$NSCOUNT"
  check "the table has rows"                     test "$ROWS" -gt 0
  check "it covers several namespaces"           test "$NSCOUNT" -ge 3
fi

check "a Jenkins pipeline was added for it" grep -q 'lakehouse-ingest-pods' "$ROOT/clusters/home-lab/jenkins/jenkins.yaml"
summary
