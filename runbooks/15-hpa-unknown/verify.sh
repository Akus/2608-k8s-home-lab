#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-15
echo "15: autoscaler shows <unknown>"

hpa() { kubectl -n $NS get hpa api -o jsonpath="$1" 2>/dev/null; }
check "container has a CPU request" test -n \
  "$(kubectl -n $NS get deploy api -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
check_eq "HPA still targets 50% CPU" 50 "$(hpa '{.spec.metrics[0].resource.target.averageUtilization}')"
check_eq "HPA condition ScalingActive is True" True "$(hpa '{.status.conditions[?(@.type=="ScalingActive")].status}')"
util=$(hpa '{.status.currentMetrics[0].resource.current.averageUtilization}')
check "HPA reports a CPU percentage (currently: ${util:-<unknown>}%)" test -n "$util"

# Step 2: an HPA that has scaled up has a lastScaleTime and/or more than 1 desired replica.
if [[ -n "$(hpa '{.status.lastScaleTime}')" ]]; then
  pass "HPA has scaled at least once (last at $(hpa '{.status.lastScaleTime}'))"
else
  fail "HPA has not scaled yet: put some load on it (step 2)"
fi
summary
