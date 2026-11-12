# 01: Deploy a web app behind the ingress

No setup script: you start from an empty cluster corner. Create namespace `rb-01` yourself.

## Task

Deploy a small web app the way you'd want a production workload to look:

1. Deployment `hello` in namespace `rb-01`, image `nginx:1.27-alpine`, **2 replicas**.
2. Each container requests `50m` CPU and `32Mi` memory, and is limited to `64Mi` memory.
3. A **readiness probe** on HTTP `/` port 80, so traffic only goes to pods that answer.
4. The two replicas run on **different nodes** (`k8s-cp-1` and `k8s-w-1`), so losing one Pi
   doesn't take the app down.
5. Service `hello` (ClusterIP, port 80).
6. Ingress `hello` for host `hello.rb.lan`, class `nginx`, so that this returns 200:
   ```bash
   curl -H 'Host: hello.rb.lan' http://192.168.1.240/
   ```
   (`hello.rb.lan` isn't in DNS, the `Host` header is enough for ingress-nginx. Add it to
   `/etc/hosts` if you want to open it in a browser.)

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- `kubectl create deployment hello --image=nginx:1.27-alpine --replicas=2 --dry-run=client -o yaml > hello.yaml`
  gives you a skeleton to edit.
- Spreading: `topologySpreadConstraints` with `topologyKey: kubernetes.io/hostname`, or
  `podAntiAffinity`. Which one still schedules if a node is down?
- `kubectl create service clusterip` / `kubectl create ingress --rule=host/path=svc:port`
  also have `--dry-run=client -o yaml`.
- `kubectl -n rb-01 get endpointslices` shows whether the Service found your pods.

</details>

<details><summary>Solution</summary>

```yaml
apiVersion: v1
kind: Namespace
metadata: { name: rb-01 }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: hello, namespace: rb-01 }
spec:
  replicas: 2
  selector: { matchLabels: { app: hello } }
  template:
    metadata: { labels: { app: hello } }
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector: { matchLabels: { app: hello } }
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{ containerPort: 80 }]
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits: { memory: 64Mi }
          readinessProbe:
            httpGet: { path: /, port: 80 }
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata: { name: hello, namespace: rb-01 }
spec:
  selector: { app: hello }
  ports: [{ port: 80, targetPort: 80 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: hello, namespace: rb-01 }
spec:
  ingressClassName: nginx
  rules:
    - host: hello.rb.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: hello, port: { number: 80 } } }
```

`DoNotSchedule` keeps the skew at most 1: with one node down, the second replica stays
Pending instead of landing next to the first. `ScheduleAnyway` would prefer spreading but
fall back to a single node. A required `podAntiAffinity` behaves like `DoNotSchedule`.

</details>
