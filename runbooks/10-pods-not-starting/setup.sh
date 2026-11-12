#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-10
ensure_ns $NS

kubectl -n $NS apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: api }
spec:
  selector: { matchLabels: { app: api } }
  template:
    metadata: { labels: { app: api } }
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpinee
          resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 64Mi } }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: worker-config }
data:
  QUEUE_ULR: amqp://queue.rb-10.svc:5672
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: worker }
spec:
  selector: { matchLabels: { app: worker } }
  template:
    metadata: { labels: { app: worker } }
    spec:
      containers:
        - name: worker
          image: busybox:1.36
          command: [sh, -c, 'echo "consuming from $QUEUE_URL"; sleep 3600']
          env:
            - name: QUEUE_URL
              valueFrom: { configMapKeyRef: { name: worker-config, key: QUEUE_URL } }
          resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 32Mi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: cache }
spec:
  selector: { matchLabels: { app: cache } }
  template:
    metadata: { labels: { app: cache } }
    spec:
      containers:
        - name: cache
          image: busybox:1.36
          # "Warm-up": holds ~100 MB in memory for a moment, then idles.
          command: [sh, -c, 'head -c 100000000 /dev/zero | tail >/dev/null; echo "cache warm"; sleep 3600']
          resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { memory: 64Mi } }
EOF
echo "Deployments api, worker and cache in $NS are deployed. None of them is running."
