# Shutdown / restart

How to safely power the cluster down and back up, without corrupting etcd or
leaving pods mid-write.

Notation: **[CP]** = control-plane node only, **[W]** = worker node only.
See [IMPLEMENTATION.md](IMPLEMENTATION.md) for node naming (`k8s-cp-1`, `k8s-w-1`).

---

## Shutting down

Drain workloads first so pods get rescheduled/stopped gracefully instead of
just vanishing with the node — from your laptop (`kubectl` pointed at the
cluster):

```bash
kubectl cordon k8s-w-1
kubectl drain k8s-w-1 --ignore-daemonsets --delete-emptydir-data
kubectl cordon k8s-cp-1
kubectl drain k8s-cp-1 --ignore-daemonsets --delete-emptydir-data
```

With only 2 nodes and Longhorn replicas set to 2, draining both is mostly
about stopping app pods cleanly — CNI/Longhorn daemonset pods get killed with
the node regardless, which is fine.

Then power off **worker first, control-plane last** — etcd (on the CP) needs
a clean stop, not power pulled mid-write, so shutting it down normally (as
opposed to yanking power while it's live) is what protects it:

```bash
ssh k8s-w-1 'sudo shutdown -h now'
# wait for it to actually go down, then:
ssh k8s-cp-1 'sudo shutdown -h now'
```

Wait ~10–15 s after each SSH session drops before pulling power, so the
filesystem finishes flushing.

---

## Starting back up

Power both Pis on — order doesn't matter much. `kubelet`, `containerd`, and
`etcd` all restart automatically via systemd; no `kubeadm init` needed.

Once both nodes show `Ready`:

```bash
kubectl get nodes -o wide      # wait for Ready
kubectl uncordon k8s-cp-1
kubectl uncordon k8s-w-1
```
