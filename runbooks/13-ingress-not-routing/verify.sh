#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-13
echo "13: ingress returns 404/503"

check_eq "Service web still exposes port 8080" 8080 \
  "$(kubectl -n $NS get svc web -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)"
check_eq "Ingress web uses class nginx" nginx \
  "$(kubectl -n $NS get ingress web -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)"
check_eq "Ingress web got the ingress IP" "$INGRESS_IP" \
  "$(kubectl -n $NS get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
check_eq "curl -H 'Host: web.rb.lan' http://$INGRESS_IP/ returns 200" 200 \
  "$(http_code "http://$INGRESS_IP/" -H 'Host: web.rb.lan')"
summary
