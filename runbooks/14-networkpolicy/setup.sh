#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-14
OTHER=rb-14-other
ensure_ns $NS
ensure_ns $OTHER

kubectl -n $NS apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: backend }
spec:
  selector: { matchLabels: { app: backend } }
  template:
    metadata: { labels: { app: backend } }
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{ containerPort: 80 }]
          resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 64Mi } }
---
apiVersion: v1
kind: Service
metadata: { name: backend }
spec:
  selector: { app: backend }
  ports: [{ port: 80 }]
---
apiVersion: v1
kind: Pod
metadata: { name: frontend, labels: { app: frontend } }
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: [sleep, infinity]
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 32Mi } }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF

# Another team's namespace, no policies: an outside client, and a service frontend must not reach.
kubectl -n $OTHER apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: intruder, labels: { app: intruder } }
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: [sleep, infinity]
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 32Mi } }
---
apiVersion: v1
kind: Pod
metadata: { name: other-web, labels: { app: other-web } }
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 64Mi } }
EOF
kubectl -n $OTHER expose pod other-web --port 80 >/dev/null 2>&1 || true
echo "$NS is locked down by NetworkPolicy default-deny. Over to you."
