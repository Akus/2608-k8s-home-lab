#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
echo "24: metrics-server upgrade"

get() { kubectl -n kube-system get deploy metrics-server -o jsonpath="$1" 2>/dev/null; }
image=$(get '{.spec.template.spec.containers[0].image}')
tag=${image##*:}
newest=$(printf '%s\nv0.7.2\n' "$tag" | sort -V | tail -1)
check "metrics-server is newer than v0.7.2 (runs $tag)" test "$tag" != v0.7.2 -a "$newest" = "$tag"
check_eq "metrics-server Deployment is fully ready" 1 "$(get '{.status.readyReplicas}')"
check "--kubelet-insecure-tls is still set" bash -c "kubectl -n kube-system get deploy metrics-server \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- --kubelet-insecure-tls"
check_eq "APIService v1beta1.metrics.k8s.io is Available" True \
  "$(kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
check "kubectl top nodes works" kubectl top nodes
check "IMPLEMENTATION.md §8 mentions $tag" grep -q "metrics-server/releases/download/$tag/" \
  "$(dirname "$0")/../../IMPLEMENTATION.md"
summary
