#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-04
SA=system:serviceaccount:$NS:ci-deployer
echo "04: least-privilege CI account"

can() { kubectl auth can-i "$@" --as=$SA; }
check "ServiceAccount ci-deployer exists" kubectl -n $NS get sa ci-deployer
for verb in get list watch create update patch; do
  check "can $verb deployments in $NS" can "$verb" deployments.apps -n $NS
done
check "can list pods in $NS" can list pods -n $NS
check "can read pod logs in $NS" can get pods --subresource=log -n $NS
check_not "can NOT delete deployments" can delete deployments.apps -n $NS
check_not "can NOT read secrets" can get secrets -n $NS
check_not "can NOT create deployments in hil-lab" can create deployments.apps -n hil-lab
check_not "can NOT list pods in hil-lab" can list pods -n hil-lab
check_not "can NOT list nodes" can list nodes

kc="$(dirname "$0")/ci-deployer.kubeconfig"
check_eq "ci-deployer.kubeconfig authenticates as the ServiceAccount" "$SA" \
  "$(kubectl --kubeconfig="$kc" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)"
check "ci-deployer.kubeconfig can list deployments" kubectl --kubeconfig="$kc" -n $NS get deploy
summary
