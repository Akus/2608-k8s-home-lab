#!/usr/bin/env bash
kubectl delete namespace rb-04 --ignore-not-found
rm -f "$(dirname "$0")/ci-deployer.kubeconfig"
