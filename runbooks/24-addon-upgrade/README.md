# 24: Upgrade an add-on and roll back (real cluster)

> **Real cluster.** You're upgrading metrics-server. It's low-risk: if it breaks, only
> `kubectl top` and HPAs (scenario 15) stop working, nothing that serves traffic.

The add-ons in IMPLEMENTATION.md §8 were installed from pinned upstream manifests, and some
were patched by hand afterwards. metrics-server runs **v0.7.2** with an extra
`--kubelet-insecure-tls` flag.

## Task

1. Find the newest metrics-server release. Read its release notes between v0.7.2 and
   that version: anything that affects this cluster?
2. Before applying anything, see **exactly** what the new manifest would change in the
   cluster. Does the diff show anything you didn't expect?
3. Upgrade, so that `kubectl top nodes` still works afterwards.
4. Practise the rollback: go back to v0.7.2, confirm it works, then upgrade again.
5. Make the next upgrade harder to get wrong: update IMPLEMENTATION.md §8 with the new
   version, and think about how the hand-applied patch could be made part of the manifest
   (see FLUX-MIGRATION-PLAN.md).

```bash
./verify.sh
```

<details><summary>Hints</summary>

- Releases: https://github.com/kubernetes-sigs/metrics-server/releases. The manifest is the
  `components.yaml` asset of each release.
- `kubectl diff -f <url>` compares a manifest against the live objects without changing
  anything. Read the `args` part carefully.
- `kubectl -n kube-system rollout status deploy/metrics-server`, then `kubectl top nodes`
  (give it ~30 s for the first scrape).
- Rollback options: re-apply the old manifest, or `kubectl rollout undo`. Which one also
  rolls back the RBAC and APIService objects, if the new version changed them?

</details>

<details><summary>Solution</summary>

```bash
NEW=v0.X.Y    # newest release
kubectl diff -f https://github.com/kubernetes-sigs/metrics-server/releases/download/$NEW/components.yaml
```

The surprise in the diff: besides the image tag, `--kubelet-insecure-tls` **disappears**
from the args. The upstream manifest doesn't have it, and applying it replaces the whole
list. Applied as is, the new pods can't scrape the kubelets (self-signed serving certs,
scenario 23), never get Ready, and `kubectl top` breaks. Every raw-manifest upgrade silently
drops hand-applied patches.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/$NEW/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deploy/metrics-server
kubectl top nodes
```

Rollback: re-apply the v0.7.2 manifest (plus the patch again). `kubectl rollout undo` only
rolls back the Deployment's pod template. If the new release also changed RBAC or the
APIService, those stay on the new version. A full manifest re-apply restores all of it.

The lasting fix is a `kustomization.yaml` that pins the upstream URL and carries the patch,
as in FLUX-MIGRATION-PLAN.md. Then an upgrade is a one-line version bump, and
`kubectl diff -k` shows only the intended change.

</details>
