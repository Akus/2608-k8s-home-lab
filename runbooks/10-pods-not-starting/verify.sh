#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-10
echo "10: three pods that won't start"

ready() { kubectl -n $NS get deploy "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null; }
pod() { kubectl -n $NS get pods -l "app=$1" --field-selector=status.phase=Running -o name 2>/dev/null | head -1; }

check_eq "api is ready" 1 "$(ready api)"
check_eq "api runs nginx:1.27-alpine" nginx:1.27-alpine \
  "$(kubectl -n $NS get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"

check_eq "worker is ready" 1 "$(ready worker)"
check_eq "worker's QUEUE_URL comes from ConfigMap worker-config" worker-config \
  "$(kubectl -n $NS get deploy worker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="QUEUE_URL")].valueFrom.configMapKeyRef.name}' 2>/dev/null)"
p=$(pod worker)
check_eq "worker sees QUEUE_URL" amqp://queue.rb-10.svc:5672 \
  "$( [[ -n $p ]] && kubectl -n $NS exec "$p" -- printenv QUEUE_URL 2>/dev/null)"

check_eq "cache is ready" 1 "$(ready cache)"
limit=$(kubectl -n $NS get deploy cache -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)
case "$limit" in # to Mi
  *Mi) mi=${limit%Mi} ;;
  *Gi) mi=$((${limit%Gi} * 1024)) ;;
  *M) mi=$((${limit%M} * 1000000 / 1048576)) ;;
  *[0-9]) mi=$((limit / 1048576)) ;;
  *) mi=0 ;;
esac
check "cache memory limit (${limit:-none}) is set and <= 256Mi" test "$mi" -gt 0 -a "$mi" -le 256
p=$(pod cache)
check "cache finished its warm-up" bash -c "[[ -n '$p' ]] && kubectl -n $NS logs '$p' | grep -q 'cache warm'"
summary
