#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
echo "20: worker back in service after maintenance"

check_eq "$WORKER is Ready" True \
  "$(kubectl get node "$WORKER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
check_eq "$WORKER is schedulable (uncordoned)" "" \
  "$(kubectl get node "$WORKER" -o jsonpath='{.spec.unschedulable}')"
pending=$(kubectl get pods -A --field-selector=status.phase=Pending -o name | wc -l)
check_eq "no Pending pods anywhere" 0 "$pending"
not_ready=$(kubectl -n hil-lab get deploy -o jsonpath='{range .items[*]}{.metadata.name} {.spec.replicas} {.status.readyReplicas}{"\n"}{end}' |
  awk '$2 != $3 {print $1}' | tr '\n' ' ')
check_eq "all hil-lab Deployments fully ready" "" "$not_ready"
check_eq "ingress still answers on $INGRESS_IP" 404 "$(http_code "http://$INGRESS_IP/" -H 'Host: nothing.invalid')"
summary
