# 11: Three pods stuck Pending

```bash
./setup.sh
```

## Situation

`batch`, `ml-job` and `reports` in `rb-11` were deployed an hour ago. Their pods are still
`Pending`. Nothing is crashing; they never got as far as starting.

## Task

Get all three running, with these constraints from the teams that own them:

- `batch` really only needs a tenth of a CPU. Request **at most 500m**.
- `ml-job` has no GPU dependency after all, but must run on **`k8s-w-1`**.
- `reports` keeps its data on a PVC named `reports-data`, using the cluster's real
  StorageClass.

For each, find the scheduler's exact reason before changing anything.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- `kubectl -n rb-11 describe pod <pod>`: the `FailedScheduling` event says why for each node:
  "0/2 nodes are available: ...".
- `kubectl describe node k8s-w-1`: compare `Capacity`/`Allocatable` and `Allocated resources`.
- `kubectl get nodes --show-labels`: which labels can you select a node with?
- `kubectl get storageclass`, `kubectl -n rb-11 describe pvc reports-data`. Can you change a
  PVC's `storageClassName` after it's created?

</details>

<details><summary>Solution</summary>

| Pod | Scheduler says | Fix |
|---|---|---|
| `batch` | `Insufficient cpu`: requests 6 CPUs, a Pi 4 has 4 | `kubectl -n rb-11 set resources deploy/batch --requests=cpu=100m` |
| `ml-job` | `didn't match Pod's node affinity/selector`: no node has `accelerator=nvidia` | replace the nodeSelector with `kubernetes.io/hostname: k8s-w-1` |
| `reports` | `unbound immediate PersistentVolumeClaims` | PVC is Pending: StorageClass `fast-ssd` doesn't exist. `storageClassName` is immutable, so delete the PVC and re-create it with `local-path` (or no class, since `local-path` is the default) |

```bash
kubectl -n rb-11 patch deploy ml-job --type=json -p='[{"op":"replace",
  "path":"/spec/template/spec/nodeSelector","value":{"kubernetes.io/hostname":"k8s-w-1"}}]'

kubectl -n rb-11 get pvc reports-data -o yaml > pvc.yaml   # edit storageClassName, drop status/uid
kubectl -n rb-11 delete pvc reports-data
kubectl -n rb-11 apply -f pvc.yaml
```

The PVC delete may hang on the `kubernetes.io/pvc-protection` finalizer while the Pending pod
still references it. It completes once the pod is gone. Scale `reports` to 0 first, or
just let the Deployment re-create the pod.

Labelling a node `accelerator=nvidia` would also have "fixed" `ml-job`, but it puts a lie
in the cluster that the next GPU workload would trust.

</details>
