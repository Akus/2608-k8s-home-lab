#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-12
echo "12: service reachable but nothing answers"

check "readiness probe is still configured" test -n \
  "$(kubectl -n $NS get deploy backend -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)"
check_eq "backend has 2 ready replicas" 2 \
  "$(kubectl -n $NS get deploy backend -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
ready_eps=$(kubectl -n $NS get endpointslices -l kubernetes.io/service-name=backend \
  -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}x{"\n"}{end}' 2>/dev/null | grep -c x)
check_eq "Service backend has 2 ready endpoints" 2 "$ready_eps"

# Several requests, so both endpoints are very likely hit at least once.
codes=$(for _ in 1 2 3 4 5 6; do
  kubectl -n $NS exec client -- curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend 2>/dev/null || echo 000
done | sort -u | tr '\n' ' ')
check_eq "client gets 200 from http://backend every time" "200 " "$codes"
summary
