#!/usr/bin/env bash
# REAL CLUSTER: breaks the kubelet on the worker node.
source "$(dirname "$0")/../lib.sh"

cat <<EOF
This breaks the kubelet on $WORKER. After ~5 minutes Kubernetes evicts its pods;
hil-lab pods with local-path volumes on $WORKER can't move and stay Pending until you fix it.
EOF
read -rp "Type 'break it' to continue: " answer
[[ "$answer" == "break it" ]] || { echo "Aborted."; exit 1; }

ssh -o BatchMode=yes "$WORKER" 'set -e
  sudo fallocate -l 256M /swapfile-rb16
  sudo chmod 600 /swapfile-rb16
  sudo mkswap /swapfile-rb16 >/dev/null
  sudo swapon /swapfile-rb16
  sudo systemctl disable kubelet 2>/dev/null
  sudo systemctl restart kubelet'
echo "Done. Watch: kubectl get nodes -w"
