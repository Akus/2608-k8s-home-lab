# 14: Locked-down namespace, open one path

```bash
./setup.sh
```

## Situation

Security has locked down namespace `rb-14` with NetworkPolicy `default-deny`: no traffic in
or out of any pod. Now `frontend` can't reach `backend` any more:

```bash
kubectl -n rb-14 exec frontend -- curl -sv -m 5 http://backend
```

## Task

Open exactly the paths needed, nothing more:

1. `frontend` reaches `backend` on port 80 **by Service name** (`http://backend`).
2. Nothing else can reach `backend`: not `intruder` in namespace `rb-14-other`, which has no
   policies of its own.
3. `frontend` can't reach anything else either, e.g. `http://other-web.rb-14-other`.
4. Keep `default-deny` in place. Add policies, don't delete it.

The cluster's CNI, Calico, enforces NetworkPolicy. Not every CNI does (Flannel doesn't).

```bash
./verify.sh
./cleanup.sh   # removes both namespaces
```

<details><summary>Hints</summary>

- Policies are additive allow-lists: traffic is allowed if **any** policy selecting the pod
  allows it. `default-deny` selects every pod and allows nothing.
- A connection needs two allows: **egress** from the client and **ingress** to the server.
- "By Service name" means DNS first. Where does `frontend` send its DNS queries?
  `kubectl -n kube-system get pods -l k8s-app=kube-dns`, and `cat /etc/resolv.conf` in the pod.
- Policies match pods, not Services: use the backend **pod's** labels and its container port.
- Test the deny paths as well: `kubectl -n rb-14-other exec intruder -- curl -m 3 http://backend.rb-14`.

</details>

<details><summary>Solution</summary>

```yaml
# frontend may send DNS to CoreDNS and HTTP to backend, nothing else
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: frontend-egress, namespace: rb-14 }
spec:
  podSelector: { matchLabels: { app: frontend } }
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
    - to:
        - podSelector: { matchLabels: { app: backend } }
      ports: [{ protocol: TCP, port: 80 }]
---
# backend accepts HTTP from frontend only
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: backend-ingress, namespace: rb-14 }
spec:
  podSelector: { matchLabels: { app: backend } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: frontend } }
      ports: [{ protocol: TCP, port: 80 }]
```

The `namespaceSelector` and `podSelector` in the DNS rule are in the **same** list item,
so they mean "CoreDNS pods in kube-system". Written as two items (`- namespaceSelector` and
`- podSelector`), it would mean "anything in kube-system, or kube-dns-labelled pods in
rb-14". That's the most common NetworkPolicy mistake.

A bare `podSelector` in `from`/`to` only matches pods in the policy's own namespace, so
`intruder` would stay out even if it were labelled `app: frontend`.

</details>
