#!/usr/bin/env bash
kubectl delete namespace rb-11 --ignore-not-found
rm -f "$(dirname "$0")/pvc.yaml"
