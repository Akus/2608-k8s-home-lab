#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-14
OTHER=rb-14-other
echo "14: open one path through a locked-down namespace"

curl_from() { # NS POD URL -> http code, 000 if blocked
  kubectl -n "$1" exec "$2" -- curl -s -m 4 -o /dev/null -w '%{http_code}' "$3" 2>/dev/null || true
}
check "NetworkPolicy default-deny still exists" kubectl -n $NS get networkpolicy default-deny
check_eq "default-deny still selects all pods, both directions" "Ingress Egress" \
  "$(kubectl -n $NS get networkpolicy default-deny -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null)"
check_eq "frontend -> http://backend returns 200" 200 "$(curl_from $NS frontend http://backend)"
check_eq "intruder ($OTHER) -> backend is blocked" 000 "$(curl_from $OTHER intruder http://backend.$NS)"
check_eq "intruder can still reach other-web (the deny is backend's, not a broken test pod)" 200 \
  "$(curl_from $OTHER intruder http://other-web)"
other_ip=$(kubectl -n $OTHER get pod other-web -o jsonpath='{.status.podIP}')
check_eq "frontend -> other-web ($OTHER) is blocked, even by IP" 000 "$(curl_from $NS frontend "http://$other_ip")"
summary
