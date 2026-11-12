#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
echo "16: worker is NotReady"

on_worker() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$WORKER" "$@" 2>/dev/null; }
check_eq "$WORKER is Ready" True \
  "$(kubectl get node "$WORKER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
check_eq "no swap active on $WORKER" "" "$(on_worker swapon --noheadings --show)"
check_not "no swap entry in $WORKER's /etc/fstab" on_worker "grep -E '^[^#].*\sswap\s' /etc/fstab"
check_eq "kubelet is active" active "$(on_worker systemctl is-active kubelet)"
check_eq "kubelet is enabled (survives a reboot)" enabled "$(on_worker systemctl is-enabled kubelet)"
summary
