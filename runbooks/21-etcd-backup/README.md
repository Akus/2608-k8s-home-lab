# 21: Back up etcd, and optionally restore it (real cluster)

> **Real cluster.** The backup part is harmless. The restore drill in Part 3 rolls the whole
> cluster back to the snapshot's moment and takes the API server down for a few minutes.
> Only do it when that's OK.

etcd holds every object in the cluster: Deployments, Secrets, CRDs, everything. A volume
backup (Longhorn) protects data, but an etcd snapshot protects the cluster's state.
Do this before every upgrade (scenario 22).

## Task

**Part 1: snapshot.**
1. Take an etcd snapshot on `k8s-cp-1` and check that it's valid (revision, key count, size).
2. Copy it off the node to `runbooks/21-etcd-backup/backups/` on your laptop. `*.db` is gitignored.
   **Never** commit it: it contains every Secret in plain text.

**Part 2: what else a restore needs.**
3. A snapshot alone isn't enough to rebuild a dead control-plane node. What else would you
   need from `k8s-cp-1`? Back that up too, and keep it as safe as the snapshot.

**Part 3 (optional): restore drill.**
4. Take a fresh snapshot, then create a namespace `rb-21-canary`.
5. Restore the snapshot. Afterwards `rb-21-canary` must be gone, because it didn't exist yet
   at snapshot time, and everything else must be back up.

```bash
./verify.sh    # checks Part 1 (and Part 2 if you used backups/pki.tgz)
```

<details><summary>Hints</summary>

- etcd runs as a static pod, `etcd-k8s-cp-1`. Its image ships `etcdctl` and `etcdutl`, and
  it mounts `/var/lib/etcd` (data) and `/etc/kubernetes/pki/etcd` (certs) from the host.
  `kubectl -n kube-system get pod etcd-k8s-cp-1 -o yaml` shows the flags with the cert paths.
- etcd only talks TLS with client certs: `--cacert`, `--cert`, `--key`, `--endpoints`.
- `etcdctl snapshot save` takes the snapshot, `etcdutl snapshot status` checks it.
- Static pods are started by the kubelet from `/etc/kubernetes/manifests/`. Moving a
  manifest out of that directory stops the pod.

</details>

<details><summary>Solution</summary>

**Part 1**

```bash
ETCDCTL="kubectl -n kube-system exec etcd-k8s-cp-1 -- etcdctl --endpoints=https://127.0.0.1:2379
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt
  --key=/etc/kubernetes/pki/etcd/server.key"
SNAP=snapshot-$(date +%F-%H%M).db

$ETCDCTL snapshot save /var/lib/etcd/$SNAP
kubectl -n kube-system exec etcd-k8s-cp-1 -- etcdutl snapshot status /var/lib/etcd/$SNAP -w table

mkdir -p runbooks/21-etcd-backup/backups
ssh k8s-cp-1 "sudo cat /var/lib/etcd/$SNAP" > runbooks/21-etcd-backup/backups/$SNAP
ssh k8s-cp-1 "sudo sha256sum /var/lib/etcd/$SNAP"; sha256sum runbooks/21-etcd-backup/backups/$SNAP
```

**Part 2**: the **PKI**, `/etc/kubernetes/pki`. A new control plane must have the same CA,
or no kubelet, kubeconfig or ServiceAccount token issued so far would be trusted any more.
The snapshot plus the PKI is enough to rebuild with `kubeadm init` on a new SSD.

```bash
ssh k8s-cp-1 'sudo tar czf - -C /etc/kubernetes pki' > runbooks/21-etcd-backup/backups/pki.tgz
```

**Part 3**: restore. While etcd still runs, its own `etcdutl` restores into a new
directory. The flags make the restored member match the existing one:

```bash
$ETCDCTL snapshot save /var/lib/etcd/drill.db
kubectl create namespace rb-21-canary
kubectl -n kube-system exec etcd-k8s-cp-1 -- etcdutl snapshot restore /var/lib/etcd/drill.db \
  --data-dir /var/lib/etcd/restored --name k8s-cp-1 \
  --initial-cluster k8s-cp-1=https://192.168.1.11:2380 \
  --initial-advertise-peer-urls https://192.168.1.11:2380

ssh k8s-cp-1
sudo mv /etc/kubernetes/manifests/{kube-apiserver,etcd}.yaml /etc/kubernetes/
sudo crictl ps | grep -E 'etcd|kube-apiserver'      # repeat until empty
sudo mv /var/lib/etcd /var/lib/etcd.old
sudo mv /var/lib/etcd.old/restored /var/lib/etcd
sudo mv /etc/kubernetes/{etcd,kube-apiserver}.yaml /etc/kubernetes/manifests/
sudo systemctl restart kubelet
exit
ssh k8s-w-1 sudo systemctl restart kubelet

kubectl get nodes                      # API back after ~1 min
kubectl get ns rb-21-canary            # NotFound
kubectl get pods -A | grep -v -E 'Running|Completed'
```

Once everything is healthy: `ssh k8s-cp-1 sudo rm -rf /var/lib/etcd.old`. Keep
`/var/lib/etcd.old` until then: it's your way back if the restore went wrong.

</details>
