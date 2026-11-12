#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=lakehouse

if [[ -f /tmp/rb30-secret-backup.yaml ]]; then
  kubectl -n $NS delete secret lakehouse-s3-credentials >/dev/null 2>&1 || true
  kubectl apply -f /tmp/rb30-secret-backup.yaml >/dev/null
  rm -f /tmp/rb30-secret-backup.yaml
  kubectl -n $NS rollout restart deploy/iceberg-rest >/dev/null
  echo "Original Secret restored, iceberg-rest restarting."
else
  echo "No backup found; nothing to restore."
fi
kubectl -n $NS delete job -l job-name --field-selector status.successful=0 >/dev/null 2>&1 || true
kubectl -n $NS get job -o name 2>/dev/null | grep -E 'rb30' | xargs -r kubectl -n $NS delete >/dev/null 2>&1 || true
