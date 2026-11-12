#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=lakehouse

kubectl -n $NS get secret lakehouse-s3-credentials -o yaml > /tmp/rb30-secret-backup.yaml 2>/dev/null || {
  echo "lakehouse-s3-credentials not found — is the lakehouse deployed? (see LAKEHOUSE.md)"; exit 1; }

REAL_SECRET=$(kubectl -n $NS get secret lakehouse-s3-credentials -o jsonpath='{.data.secret-access-key}' | base64 -d)

kubectl -n $NS delete secret lakehouse-s3-credentials >/dev/null
kubectl -n $NS create secret generic lakehouse-s3-credentials \
  --from-literal=access-key-id='GK00000000000000deadbeef' \
  --from-literal=secret-access-key="$REAL_SECRET" >/dev/null

kubectl -n $NS rollout restart deploy/iceberg-rest >/dev/null
kubectl -n $NS rollout status deploy/iceberg-rest --timeout=180s >/dev/null

echo "Done. The lakehouse is up but Spark jobs that write data now fail."
echo "Backup of the original Secret: /tmp/rb30-secret-backup.yaml (don't peek yet)."
