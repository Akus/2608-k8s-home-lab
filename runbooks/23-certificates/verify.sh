#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
baseline="$(dirname "$0")/.baseline"
echo "23: certificates"

[[ -f $baseline ]] || { echo "Run ./setup.sh first, before renewing anything."; exit 1; }
source "$baseline"
epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }

served=$(echo | openssl s_client -connect 192.168.1.11:6443 2>/dev/null | openssl x509 -noout -startdate | cut -d= -f2)
check "API server serves a renewed certificate (from $served, was $APISERVER_START)" \
  test "$(epoch "$served")" -gt "$(epoch "$APISERVER_START")"
client=$(kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' |
  base64 -d | openssl x509 -noout -startdate | cut -d= -f2)
check "your kubeconfig has a renewed client certificate (from $client, was $CLIENT_START)" \
  test "$(epoch "$client")" -gt "$(epoch "$CLIENT_START")"
check "kubectl still works with it" kubectl get nodes

if kubectl -n hil-lab get certificate lab-wildcard >/dev/null 2>&1; then
  secret_end=$(kubectl -n hil-lab get secret lab-wildcard-tls -o jsonpath='{.data.tls\.crt}' |
    base64 -d | openssl x509 -noout -enddate | cut -d= -f2)
  served_end=$(echo | openssl s_client -connect "$INGRESS_IP:443" -servername jenkins.lab.akos-demo.com 2>/dev/null |
    openssl x509 -noout -enddate | cut -d= -f2)
  check_eq "ingress serves the certificate from lab-wildcard-tls" "$secret_end" "$served_end"
  revision=$(kubectl -n hil-lab get certificate lab-wildcard -o jsonpath='{.status.revision}')
  check "lab-wildcard has been renewed at least once (revision ${revision:-?} >= 2)" test "${revision:-0}" -ge 2
else
  echo "  SKIP ingress checks: Certificate hil-lab/lab-wildcard doesn't exist yet (HTTPS not set up)"
fi
summary
