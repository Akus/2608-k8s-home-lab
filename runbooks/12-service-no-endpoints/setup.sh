#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-12
ensure_ns $NS

kubectl -n $NS apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: backend }
spec:
  replicas: 2
  selector: { matchLabels: { app: backend, tier: api } }
  template:
    metadata: { labels: { app: backend, tier: api } }
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{ name: http, containerPort: 80 }]
          readinessProbe:
            httpGet: { path: /healthz, port: 80 }
            periodSeconds: 5
          resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 64Mi } }
---
apiVersion: v1
kind: Service
metadata: { name: backend }
spec:
  selector: { app: back-end }
  ports: [{ port: 80, targetPort: 8080 }]
---
apiVersion: v1
kind: Pod
metadata: { name: client }
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: [sleep, infinity]
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 32Mi } }
EOF
echo "backend and client are deployed in $NS. Try: kubectl -n $NS exec client -- curl -sv -m 5 http://backend"
