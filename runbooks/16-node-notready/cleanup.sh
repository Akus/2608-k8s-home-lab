#!/usr/bin/env bash
# Repairs k8s-w-1 whatever state the exercise left it in.
source "$(dirname "$0")/../lib.sh"
ssh -o BatchMode=yes "$WORKER" '
  if [ -e /swapfile-rb16 ]; then sudo swapoff /swapfile-rb16 2>/dev/null; sudo rm -f /swapfile-rb16; fi
  sudo systemctl enable --now kubelet'
kubectl wait --for=condition=Ready "node/$WORKER" --timeout=120s
