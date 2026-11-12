# 10: Three pods that won't start

```bash
./setup.sh
```

## Situation

Three Deployments were just shipped to `rb-10`: `api`, `worker` and `cache`. Not one of them
has a running pod, and each fails differently.

## Task

Get all three running. For each, write down the **symptom** (the status you saw), the **cause**,
and the **command that told you**. That's the triage habit this scenario is for.

- `api` must run `nginx:1.27-alpine`.
- `worker` must get the queue URL from ConfigMap `worker-config` (no hard-coded value).
- `cache` needs about 100 MB at startup. Give it enough memory, but keep the limit at
  **256Mi or less**.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- `kubectl -n rb-10 get pods`: the STATUS column already names three different problems.
- `kubectl -n rb-10 describe pod <pod>`: read the **Events** at the bottom, and
  `Last State` / `Reason` for a container that ran and died.
- `kubectl -n rb-10 logs <pod> --previous` shows the output of the last crashed run.
- `kubectl -n rb-10 get configmap worker-config -o yaml`: look closely at the key.
- `kubectl set image`, `kubectl set resources` and `kubectl edit` all work; a re-applied
  YAML file is how you'd do it for real.

</details>

<details><summary>Solution</summary>

| Pod | Symptom | Cause | Found with |
|---|---|---|---|
| `api` | `ErrImagePull` → `ImagePullBackOff` | tag `1.27-alpinee` doesn't exist | `describe pod`: "not found" in Events |
| `worker` | `CreateContainerConfigError` | env refers to key `QUEUE_URL`, the ConfigMap has `QUEUE_ULR` | `describe pod`: "couldn't find key QUEUE_URL" |
| `cache` | `OOMKilled` → `CrashLoopBackOff` | 64Mi limit, needs ~100 MB | `describe pod`: Last State Terminated, Reason OOMKilled, exit code 137 |

```bash
kubectl -n rb-10 set image deploy/api nginx=nginx:1.27-alpine

kubectl -n rb-10 patch configmap worker-config --type=json \
  -p='[{"op":"move","from":"/data/QUEUE_ULR","path":"/data/QUEUE_URL"}]'
kubectl -n rb-10 rollout restart deploy/worker   # env from a ConfigMap is only read at container start

kubectl -n rb-10 set resources deploy/cache --limits=memory=128Mi
```

Fixing the ConfigMap rather than the Deployment is the better fix here: other consumers may
use the same key. Either is accepted. Note the pod kept failing until it was restarted:
kubelet does retry `CreateContainerConfigError`, but with back-off, so a restart is faster.

</details>
