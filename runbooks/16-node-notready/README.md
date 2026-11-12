# 16: Worker is NotReady (real cluster)

> **Real cluster.** `setup.sh` breaks the kubelet on `k8s-w-1`. After about 5 minutes,
> Kubernetes evicts the node's pods. The hil-lab pods whose local-path volumes live on
> `k8s-w-1` can't move and stay Pending until the node is back. Pick a time when the lab
> can be down for a while. `cleanup.sh` repairs everything if you give up.

```bash
./setup.sh
```

## Situation

Monitoring says `k8s-w-1` went `NotReady`. Nobody touched it, they say.

## Task

1. Get `k8s-w-1` back to `Ready`.
2. Make sure it **stays** fixed after a reboot of the Pi. The verify script checks that,
   it doesn't reboot it for you.
3. Explain what happened to the pods that were on `k8s-w-1` while it was down, and why some
   of them came back on their own while others were stuck.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- From outside: `kubectl get nodes`, `kubectl describe node k8s-w-1` (Conditions, and the
  `node.kubernetes.io/unreachable` taint).
- On the node: `ssh k8s-w-1`, then `systemctl status kubelet` and
  `journalctl -u kubelet -n 50 --no-pager`. The last error before each restart is the one
  that matters.
- `systemctl status` shows two things in its header line: whether the unit is running, and
  whether it's **enabled**.
- IMPLEMENTATION.md's troubleshooting table has seen this one before.

</details>

<details><summary>Solution</summary>

Two faults:

1. **Swap is on** (`/swapfile-rb16`). With the default `failSwapOn: true`, kubelet refuses
   to start: `journalctl -u kubelet` shows "running with swap on is not supported". systemd
   restarts it every few seconds and it fails every time.
2. **kubelet is disabled.** It still runs now, but after a reboot it wouldn't start at all.

```bash
ssh k8s-w-1
sudo swapoff /swapfile-rb16 && sudo rm /swapfile-rb16
grep swap /etc/fstab            # make sure nothing turns it back on at boot
sudo systemctl enable --now kubelet
exit
kubectl get nodes -w
```

The pods: after the node had been unreachable for 300 s (the default
`tolerationSeconds` for the `unreachable` taint), the node lifecycle controller evicted its
pods. Deployments re-created them on `k8s-cp-1`, unless they mount a local-path PVC: its
PV has `nodeAffinity` to `k8s-w-1`, so those replacements stayed Pending ("volume node
affinity conflict") until the node came back. That's the cost of node-local storage, and
the reason for Longhorn (IMPLEMENTATION.md §7, option B).

</details>
