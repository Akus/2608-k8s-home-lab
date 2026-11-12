#!/usr/bin/env bash
# Records the current certificates' start dates, so verify.sh can tell they were renewed.
source "$(dirname "$0")/../lib.sh"
apiserver_start=$(echo | openssl s_client -connect 192.168.1.11:6443 2>/dev/null | openssl x509 -noout -startdate | cut -d= -f2)
client_start=$(kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' |
  base64 -d | openssl x509 -noout -startdate | cut -d= -f2)
printf 'APISERVER_START=%q\nCLIENT_START=%q\n' "$apiserver_start" "$client_start" > "$(dirname "$0")/.baseline"
echo "Baseline recorded: API server cert from $apiserver_start, your kubeconfig's cert from $client_start."
