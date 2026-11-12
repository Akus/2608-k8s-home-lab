#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=lakehouse
G() { kubectl -n $NS exec garage-0 -- /garage "$@" 2>/dev/null; }

KEY=$(kubectl -n $NS get secret lakehouse-s3-credentials -o jsonpath='{.data.access-key-id}' 2>/dev/null | base64 -d)
KEYS=$(G key list)

check_not "the original 'lakehouse-key' is gone from Garage" grep -q 'lakehouse-key$' <<<"$KEYS"
check "the Secret's key id still exists in Garage" grep -q "$KEY" <<<"$KEYS"
check "that key has RW on the lakehouse bucket" bash -c "kubectl -n $NS exec garage-0 -- /garage bucket info lakehouse 2>/dev/null | grep -q '$KEY'"
check "iceberg-rest is Ready" test "$(kubectl -n $NS get deploy iceberg-rest -o jsonpath='{.status.readyReplicas}')" = "1"

echo
echo "Proving the rotated key actually works (~90s):"
JOB=rb31-verify-$RANDOM
sed -e "s/__JOB__/$JOB/" -e 's/__SCRIPT__/ingest_samples.py/' \
  "$(dirname "$0")/../../clusters/home-lab/lakehouse/spark/spark-job.yaml" | kubectl apply -f - >/dev/null
kubectl -n $NS wait --for=condition=complete --timeout=300s job/$JOB >/dev/null 2>&1
check_eq "a Spark job writes successfully with the new key" "1" "$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}' 2>/dev/null)"
kubectl -n $NS delete job $JOB --wait=false >/dev/null 2>&1

summary
