# 12: Service reachable but nothing answers

```bash
./setup.sh
```

## Situation

In `rb-12`, the `client` pod can't talk to the `backend` Service:

```bash
kubectl -n rb-12 exec client -- curl -sv -m 5 http://backend
```

The name resolves, but the request goes nowhere. The backend team says "the pods are
running, it must be the network".

## Task

Make `curl http://backend` from `client` return the nginx welcome page (HTTP 200), through
the Service, from **both** backend replicas. There's more than one fault. Keep the readiness
probe: removing it would hide the next real outage.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- Start at the end of the chain: `kubectl -n rb-12 get endpointslices -l kubernetes.io/service-name=backend`.
  No endpoints means the Service's selector matches no pods. Endpoints that are there
  but not ready mean the pods' readiness probe fails.
- Compare `kubectl -n rb-12 get svc backend -o yaml` with `kubectl -n rb-12 get pods --show-labels`.
- `kubectl -n rb-12 get pods` shows `0/1` READY although STATUS is Running. Why?
- Once the endpoints are ready: which port does the Service send traffic to, and which
  port does nginx listen on?

</details>

<details><summary>Solution</summary>

Three faults, in the order you meet them when following the chain Service → endpoints →
pod port:

1. **Selector**: the Service selects `app: back-end`, the pods are `app: backend`. No
   endpoints at all.
2. **Readiness**: the probe hits `/healthz`, which stock nginx answers with 404, so the pods
   never become Ready and are left out of the Service. Point the probe at `/`.
3. **targetPort**: the Service forwards to `8080`, nginx listens on `80`. Connection refused.
   Better: `targetPort: http`, the container port's name, so a port change in the
   Deployment can't break the Service again.

```bash
kubectl -n rb-12 patch svc backend --type=merge \
  -p '{"spec":{"selector":{"app":"backend"},"ports":[{"port":80,"targetPort":"http"}]}}'
kubectl -n rb-12 patch deploy backend --type=json -p='[{"op":"replace",
  "path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
kubectl -n rb-12 exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://backend
```

</details>
