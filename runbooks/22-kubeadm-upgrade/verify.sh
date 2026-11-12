#!/usr/bin/env bash
# Checks the cluster is consistently on a version >= MIN_MINOR (default 32).
source "$(dirname "$0")/../lib.sh"
MIN_MINOR=${MIN_MINOR:-32}
echo "22: Kubernetes upgrade to >= 1.$MIN_MINOR"

server=$(kubectl version -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"\(v[^"]*\)".*/\1/p' | tail -1)
minor=$(echo "$server" | cut -d. -f2)
check "API server is >= v1.$MIN_MINOR (is $server)" test "${minor:-0}" -ge "$MIN_MINOR"

check_eq "kubeadm-config records $server" "$server" \
  "$(kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | sed -n 's/^kubernetesVersion: *//p')"
for comp in kube-apiserver kube-controller-manager kube-scheduler kube-proxy; do
  imgs=$(kubectl -n kube-system get pods -l component=$comp -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null)
  [[ $comp == kube-proxy ]] && imgs=$(kubectl -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.containers[0].image}')
  check "$comp runs $server" bash -c "[[ -n '$imgs' ]] && ! grep -v -q ':$server\$' <<< '$imgs'"
done

while read -r node kubelet ready unsched; do
  check_eq "$node kubelet is $server" "$server" "$kubelet"
  check_eq "$node is Ready" True "$ready"
  check_eq "$node is schedulable" "<none>" "$unsched"
done < <(kubectl get nodes --no-headers -o custom-columns='N:.metadata.name,V:.status.nodeInfo.kubeletVersion,R:.status.conditions[?(@.type=="Ready")].status,U:.spec.unschedulable')

check_eq "kubelet/kubeadm/kubectl are on apt hold on $CONTROL_PLANE" "kubeadm kubectl kubelet" \
  "$(ssh -o BatchMode=yes "$CONTROL_PLANE" apt-mark showhold | grep -E '^kube' | sort | tr '\n' ' ' | sed 's/ $//')"
check_eq "kubelet/kubeadm/kubectl are on apt hold on $WORKER" "kubeadm kubectl kubelet" \
  "$(ssh -o BatchMode=yes "$WORKER" apt-mark showhold | grep -E '^kube' | sort | tr '\n' ' ' | sed 's/ $//')"
check_eq "ansible k8s_minor updated" "\"1.$minor\"" \
  "$(sed -n 's/^k8s_minor: *//p' "$(dirname "$0")/../../ansible/group_vars/all.yml")"
summary
