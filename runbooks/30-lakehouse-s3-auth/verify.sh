#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=lakehouse

KEY=$(kubectl -n $NS get secret lakehouse-s3-credentials -o jsonpath='{.data.access-key-id}' 2>/dev/null | base64 -d)
check_not "the Secret no longer holds the bogus key" test "$KEY" = "GK00000000000000deadbeef"

GARAGE_KEYS=$(kubectl -n $NS exec garage-0 -- /garage key list 2>/dev/null | grep -c "$KEY" || echo 0)
check "the access key id is one Garage actually issued" test "$GARAGE_KEYS" -ge 1

POD_ENV=$(kubectl -n $NS get pod -l app.kubernetes.io/name=iceberg-rest -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)
SECRET_TS=$(kubectl -n $NS get secret lakehouse-s3-credentials -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
check "iceberg-rest was restarted after the Secret was fixed" test "$POD_ENV" '>' "$SECRET_TS"

check "iceberg-rest is Ready" test "$(kubectl -n $NS get deploy iceberg-rest -o jsonpath='{.status.readyReplicas}')" = "1"

echo
echo "Final check — a real write (takes ~90s):"
JOB=rb30-verify-$RANDOM
sed -e "s/__JOB__/$JOB/" -e 's/__SCRIPT__/ingest_samples.py/' \
  "$(dirname "$0")/../../clusters/home-lab/lakehouse/spark/spark-job.yaml" | kubectl apply -f - >/dev/null
kubectl -n $NS wait --for=condition=complete --timeout=300s job/$JOB >/dev/null 2>&1
check_eq "a Spark job that writes to S3 succeeds" "1" "$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}' 2>/dev/null)"
kubectl -n $NS delete job $JOB --wait=false >/dev/null 2>&1

summary
