#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-11
echo "11: three pods stuck Pending"

ready() { kubectl -n $NS get deploy "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null; }
podjp() { kubectl -n $NS get pods -l "app=$1" --field-selector=status.phase=Running -o jsonpath="$2" 2>/dev/null; }

check_eq "batch is ready" 1 "$(ready batch)"
cpu=$(kubectl -n $NS get deploy batch -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)
case "$cpu" in *m) mcpu=${cpu%m} ;; "") mcpu=99999 ;; *) mcpu=$(awk "BEGIN{print int($cpu*1000)}") ;; esac
check "batch requests <= 500m CPU (has ${cpu:-none})" test "$mcpu" -le 500

check_eq "ml-job is ready" 1 "$(ready ml-job)"
check_eq "ml-job runs on k8s-w-1" k8s-w-1 "$(podjp ml-job '{.items[0].spec.nodeName}')"
check_not "no node is labelled accelerator=nvidia" \
  test -n "$(kubectl get nodes -l accelerator=nvidia -o name)"

check_eq "PVC reports-data is Bound" Bound \
  "$(kubectl -n $NS get pvc reports-data -o jsonpath='{.status.phase}' 2>/dev/null)"
check_eq "PVC reports-data uses local-path" local-path \
  "$(kubectl -n $NS get pvc reports-data -o jsonpath='{.spec.storageClassName}' 2>/dev/null)"
check_eq "reports is ready" 1 "$(ready reports)"
summary
