#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-03
echo "03: roll back the bad release"

get() { kubectl -n $NS get deploy shop -o jsonpath="$1" 2>/dev/null; }
check_eq "image is back to nginx:1.27-alpine" nginx:1.27-alpine "$(get '{.spec.template.spec.containers[0].image}')"
check_eq "GREETING is v2 (the last working release)" v2 \
  "$(get '{.spec.template.spec.containers[0].env[?(@.name=="GREETING")].value}')"
check_eq "rollout finished (all 3 replicas updated)" 3 "$(get '{.status.updatedReplicas}')"
check_eq "3 replicas available" 3 "$(get '{.status.availableReplicas}')"
check_eq "no pods left from v3" 0 "$(kubectl -n $NS get pods -l app=shop \
  -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null | grep -c alpne)"
rev=$(kubectl -n $NS get deploy shop -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null)
check "rolled back, not re-created (revision ${rev:-?} >= 4)" test "${rev:-0}" -ge 4
summary
