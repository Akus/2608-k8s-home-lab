# 15: Autoscaler shows `<unknown>`

```bash
./setup.sh
```

## Situation

Deployment `api` in `rb-15` has a HorizontalPodAutoscaler that should add replicas above 50%
CPU. It never scales, and:

```bash
kubectl -n rb-15 get hpa api      # TARGETS: cpu: <unknown>/50%
```

## Task

1. Make the HPA report a real CPU percentage.
2. Prove it works: put load on `api` and watch it scale up to more than 1 replica, then back
   down once the load stops. Scale-down takes ~5 minutes; read up on why.

metrics-server is installed (IMPLEMENTATION.md §8), so `kubectl top` works.

```bash
./verify.sh    # checks step 1, and step 2 if the HPA has scaled up at some point
./cleanup.sh
```

<details><summary>Hints</summary>

- `kubectl -n rb-15 describe hpa api`: read the conditions and events.
- Is metrics-server the problem? `kubectl -n rb-15 top pods`.
- Utilization is a percentage **of** something. Of what, for this container?
- Load: `kubectl -n rb-15 run load --image=busybox:1.36 --restart=Never -- sh -c 'while true; do wget -q -O- http://api >/dev/null; done'`.
  One busybox loop may not be enough against nginx; run a few, or make the request small.
- `kubectl -n rb-15 get hpa api -w` to watch.

</details>

<details><summary>Solution</summary>

`describe hpa` says `failed to get cpu utilization: missing request for cpu`. metrics-server
does have the usage (`kubectl top pods` shows it), but "50%" means 50% of the container's
**CPU request**, and the container has none. Set one:

```bash
kubectl -n rb-15 set resources deploy/api --requests=cpu=20m,memory=16Mi --limits=memory=64Mi
kubectl -n rb-15 get hpa api -w        # cpu: 0%/50% after ~30-60 s
```

A small request (20m) makes it easy to push over 50% from a Pi. In production, the
request should be what the pod really needs at normal load, because the scheduler also
uses it to place pods.

Scale-down is slow on purpose: the default `behavior.scaleDown.stabilizationWindowSeconds`
is 300, so the HPA uses the highest recommendation of the last 5 minutes and doesn't flap.

</details>
