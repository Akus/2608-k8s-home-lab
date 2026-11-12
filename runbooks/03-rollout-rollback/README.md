# 03: A bad release is half rolled out

```bash
./setup.sh
```

## Situation

Deployment `shop` in `rb-03` has had three releases. Release v3 went out a few minutes ago and
the pipeline says it "never finished". The site still seems up.

## Task

1. Find out why v3 didn't finish, and why the site is still up anyway.
2. Get `shop` back to the **last release that worked**, without deleting or re-creating the
   Deployment and without downtime.
3. Before you roll back: which release was that, and what was different between v1 and v2?
   Answer from the cluster, not from `setup.sh`.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- `kubectl -n rb-03 rollout status deploy/shop` and `kubectl -n rb-03 describe deploy shop`:
  look at the conditions.
- `kubectl -n rb-03 get rs`: how many ReplicaSets, and how many pods does each have?
- `kubectl -n rb-03 rollout history deploy/shop`, then `--revision=N` to see one in full.
- Why is the site still up? Look at the rolling update strategy.

</details>

<details><summary>Solution</summary>

```bash
kubectl -n rb-03 rollout status deploy/shop       # "exceeded its progress deadline"
kubectl -n rb-03 get pods                          # one new pod in ImagePullBackOff
kubectl -n rb-03 describe pod <that pod>           # image "nginx:1.27-alpne": typo
kubectl -n rb-03 rollout history deploy/shop
kubectl -n rb-03 rollout history deploy/shop --revision=1   # GREETING=v1
kubectl -n rb-03 rollout history deploy/shop --revision=2   # GREETING=v2, same image
kubectl -n rb-03 rollout undo deploy/shop --to-revision=2
kubectl -n rb-03 rollout status deploy/shop
```

The site stayed up because of `maxUnavailable: 0, maxSurge: 1`: the controller creates one
extra pod with the new version and only removes an old pod once a new one is Ready. The
broken pod never got Ready, so all three v2 pods kept serving. With the default (25%
unavailable) one old pod would already have been removed.

`rollout undo` doesn't "go back" in history: it copies revision 2's pod template into a
new revision, number 4. Revision 2 disappears from the list. In a GitOps setup (Flux), you
would revert the commit instead; an undo in the cluster gets overwritten on the next
reconcile.

</details>
