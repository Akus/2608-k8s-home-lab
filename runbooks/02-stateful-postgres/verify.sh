#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-02
echo "02: Postgres with persistent storage"

sts() { kubectl -n $NS get sts db -o jsonpath="$1" 2>/dev/null; }
rows() { kubectl -n $NS exec db-0 -- psql -U postgres -tAc 'SELECT count(*) FROM notes' 2>/dev/null; }

check "Secret db-credentials has key POSTGRES_PASSWORD" \
  test -n "$(kubectl -n $NS get secret db-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null)"
check_eq "StatefulSet db has 1 ready replica" 1 "$(sts '{.status.readyReplicas}')"
check_eq "image is postgres:16-alpine" postgres:16-alpine "$(sts '{.spec.template.spec.containers[0].image}')"
check_not "no literal POSTGRES_PASSWORD value in the StatefulSet" \
  test -n "$(sts '{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_PASSWORD")].value}')"
check "password comes from the Secret" bash -c "
  kubectl -n $NS get sts db -o jsonpath='{.spec.template.spec.containers[0]}' | grep -q db-credentials"
check "uses a volumeClaimTemplate" test -n "$(sts '{.spec.volumeClaimTemplates[0].metadata.name}')"
pvc="$(sts '{.spec.volumeClaimTemplates[0].metadata.name}')-db-0"
check_eq "PVC $pvc is Bound" Bound "$(kubectl -n $NS get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null)"
check_eq "Service db is headless" None "$(kubectl -n $NS get svc db -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"

before=$(rows)
check "table notes has rows (found: ${before:-none})" test "${before:-0}" -ge 1

if [[ "${before:-0}" -ge 1 ]]; then
  echo "  ... deleting pod db-0 and waiting for it to come back"
  kubectl -n $NS delete pod db-0 --wait=true >/dev/null
  kubectl -n $NS wait --for=condition=Ready pod/db-0 --timeout=180s >/dev/null 2>&1
  check_eq "rows survive the pod being re-created" "$before" "$(rows)"
fi
summary
