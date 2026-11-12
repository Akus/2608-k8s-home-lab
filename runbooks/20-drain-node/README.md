# 20: Take the worker down for maintenance (real cluster)

> **Real cluster.** Draining `k8s-w-1` moves its pods away. At the time of writing that
> includes Jenkins, Grafana, Prometheus and the ingress-nginx controller. The first three
> have local-path volumes on `k8s-w-1`, so they **can't** move and the UIs are down until
> you uncordon. That's part of what this scenario is about.

## Situation

`k8s-w-1` needs maintenance: a firmware update, a new SSD, a fan. It has to be powered off
for 15 minutes.

## Task

**Part 1: plan before you act.**
1. List what runs on `k8s-w-1` right now, and predict for each pod: does it move to
   `k8s-cp-1`, stay Pending, or just disappear? Write it down.
2. Is there anything that would block the drain?

**Part 2: drain, check your predictions, bring it back.**
3. Drain `k8s-w-1`. Compare what happened with your predictions.
4. (Optional) Power it off: `ssh k8s-w-1 sudo poweroff`, then power it back on.
5. Bring `k8s-w-1` back into service and make sure everything that moved or got stuck is
   healthy again.

**Part 3: a PodDisruptionBudget.**
6. Deploy scenario 01's solution (2 replicas of `hello`, one per node), add a PDB that keeps
   at least 1 replica available, and drain `k8s-w-1` again. What does `drain` do now, and why
   doesn't it block forever? Then do the same with `minAvailable: 2`.

```bash
./verify.sh    # after step 5: node schedulable, nothing stuck
```

<details><summary>Hints</summary>

- `kubectl get pods -A -o wide --field-selector spec.nodeName=k8s-w-1`
- For the pods with volumes: `kubectl get pv -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]`
- `kubectl drain --help`: what are `--ignore-daemonsets` and `--delete-emptydir-data` for,
  and what does drain refuse to do without them?
- `kubectl drain` = cordon + evict. Evictions respect PDBs, plain `delete` doesn't.

</details>

<details><summary>Solution</summary>

```bash
kubectl get pods -A -o wide --field-selector spec.nodeName=k8s-w-1
kubectl drain k8s-w-1 --ignore-daemonsets --delete-emptydir-data
kubectl get pods -A -o wide | grep -v Running     # what's stuck, and why: describe it
# ... maintenance ...
kubectl uncordon k8s-w-1
kubectl get pods -A -o wide -w
```

What happens to each kind of pod:

| Pod | On drain |
|---|---|
| DaemonSet pods (`calico-node`, `kube-proxy`, MetalLB `speaker`) | Stay. They belong on every node; `--ignore-daemonsets` lets drain proceed past them. |
| Deployment pods without volumes (ingress-nginx, metrics-server, cert-manager, ...) | Evicted and re-created on `k8s-cp-1`. A few seconds of downtime for single replicas. |
| Deployment pods with local-path PVCs (Jenkins, Grafana, Prometheus) | Evicted. The replacement stays **Pending**: the PV has `nodeAffinity` to `k8s-w-1`. Back once uncordoned. |
| Completed Job pods (`ingress-nginx-admission-*`) | Deleted. |

The MetalLB VIP `192.168.1.240` moves to `k8s-cp-1`'s speaker on its own (L2 failover), so
the ingress IP stays reachable even though the controller pod moved.

Uncordon doesn't move pods back. The Pending ones schedule onto `k8s-w-1` because it's the
only node their volumes fit, but everything that moved to `k8s-cp-1` stays there until it's
re-created. That's fine on a 2-node cluster, but on a bigger one you'd rebalance or use the
descheduler.

PDB: with `minAvailable: 1`, the drain evicts the `k8s-w-1` replica because one is still running
on `k8s-cp-1`. With `minAvailable: 2` the eviction is refused and drain retries every 5 s
("Cannot evict pod as it would violate the pod's disruption budget") until you Ctrl-C or set
`--timeout`. A PDB that can never be satisfied blocks every drain. Watch out for
`minAvailable` equal to the replica count.

</details>
