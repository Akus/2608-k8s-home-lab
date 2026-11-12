# 22: Upgrade Kubernetes one minor version (real cluster)

> **Real cluster.** This is the real upgrade, not a simulation. It can't be undone:
> kubeadm doesn't downgrade, and the way back is restoring etcd from scenario 21. Plan for an
> hour of partial downtime: draining each node takes its pods' UIs down for a while
> (scenario 20 shows which).

The cluster runs **v1.31**. Upgrade it to the latest **v1.32** patch release.

## Task

**Before you start, answer these:**
1. Why only one minor version? Can you go 1.31 → 1.33 directly?
2. Which order: control plane or worker first? kubeadm, kubelet or kubectl first? Why?
3. Are the add-ons ready for 1.32? Calico, MetalLB, ingress-nginx, cert-manager,
   metrics-server, local-path-provisioner. Check each project's compatibility matrix.
4. Does anything in the cluster still use an API that 1.32 removes?

**Then:**
5. Take an etcd snapshot (scenario 21).
6. Upgrade `k8s-cp-1`, then `k8s-w-1`.
7. Update the repo so a rebuild gets 1.32: `k8s_minor` in `ansible/group_vars/all.yml`, and the
   version in IMPLEMENTATION.md §5.

```bash
./verify.sh    # all nodes and the control plane on the same 1.32 version, everything healthy
```

<details><summary>Hints</summary>

- Read the official "Upgrading kubeadm clusters" page for 1.32, and the 1.32 CHANGELOG's
  "Urgent Upgrade Notes".
- `pkgs.k8s.io` has **one apt repo per minor**: 1.32 packages aren't in the v1.31 repo
  (`/etc/apt/sources.list.d/kubernetes.list`).
- The packages are on `apt-mark hold` (IMPLEMENTATION.md §5). Unhold, install, hold again.
- `sudo kubeadm upgrade plan` tells you what it will do, and checks before doing it.
- Deprecated API use: `kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis`.
- Version skew: kubelet may be older than the API server, never newer.

</details>

<details><summary>Solution</summary>

**Answers:**
1. kubeadm only supports upgrading one minor at a time; 1.33 needs 1.31 → 1.32 → 1.33.
2. Control plane first, because a kubelet must not be newer than the API server. On each
   node: kubeadm first (it does the upgrade), then kubelet and kubectl.
3. Each project publishes which Kubernetes versions it supports (Calico's "System
   requirements", ingress-nginx's "Supported Versions table", ...). If a version isn't
   listed, upgrade the add-on first (scenario 24).
4. The `apiserver_requested_deprecated_apis` metric shows deprecated API calls since the API
   server started. Also check your manifests, e.g. with `kubent` or `pluto`.

**Control plane**, on `k8s-cp-1`:

```bash
sudo sed -i 's#/v1.31/#/v1.32/#' /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo apt update
apt-cache madison kubeadm | head -3        # pick the newest, e.g. 1.32.N-1.1

V=1.32.N                                   # <- fill in
sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm="$V-*" && sudo apt-mark hold kubeadm
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply "v$V"
```

From the laptop: `kubectl drain k8s-cp-1 --ignore-daemonsets --delete-emptydir-data`, then
on `k8s-cp-1`:

```bash
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet="$V-*" kubectl="$V-*"
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
```

From the laptop: `kubectl uncordon k8s-cp-1`.

**Worker**, on `k8s-w-1`: the same repo change and kubeadm install, then
`sudo kubeadm upgrade node` (not `apply`, which is only for the control plane), then drain,
kubelet/kubectl, restart, uncordon, as above.

**Laptop**: upgrade your own `kubectl` to 1.32 as well. kubectl supports ±1 minor of the
API server.

`kubeadm upgrade apply` also renews the control plane's certificates (scenario 23), so a
cluster upgraded at least once a year never runs into the 1-year expiry.

</details>
