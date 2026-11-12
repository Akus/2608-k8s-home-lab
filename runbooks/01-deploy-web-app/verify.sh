#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-01
echo "01: web app behind the ingress"

get() { kubectl -n $NS get deploy hello -o jsonpath="$1" 2>/dev/null; }
check_eq "Deployment hello has 2 ready replicas" 2 "$(get '{.status.readyReplicas}')"
check_eq "image is nginx:1.27-alpine" nginx:1.27-alpine "$(get '{.spec.template.spec.containers[0].image}')"
check_eq "CPU request 50m" 50m "$(get '{.spec.template.spec.containers[0].resources.requests.cpu}')"
check_eq "memory request 32Mi" 32Mi "$(get '{.spec.template.spec.containers[0].resources.requests.memory}')"
check_eq "memory limit 64Mi" 64Mi "$(get '{.spec.template.spec.containers[0].resources.limits.memory}')"
check "readiness probe set" test -n "$(get '{.spec.template.spec.containers[0].readinessProbe}')"

sel=$(selector $NS hello)
nodes=$(kubectl -n $NS get pods -l "$sel" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | grep -c .)
check_eq "replicas run on 2 different nodes" 2 "$nodes"

ready_eps=$(kubectl -n $NS get endpointslices -l kubernetes.io/service-name=hello \
  -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}x{"\n"}{end}' 2>/dev/null | grep -c x)
check_eq "Service hello has 2 ready endpoints" 2 "$ready_eps"

check_eq "Ingress uses class nginx" nginx "$(kubectl -n $NS get ingress hello -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)"
check_eq "curl -H 'Host: hello.rb.lan' http://$INGRESS_IP/ returns 200" 200 \
  "$(http_code "http://$INGRESS_IP/" -H 'Host: hello.rb.lan')"
summary
