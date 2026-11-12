#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-11
ensure_ns $NS

kubectl -n $NS apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: batch }
spec:
  selector: { matchLabels: { app: batch } }
  template:
    metadata: { labels: { app: batch } }
    spec:
      containers:
        - name: batch
          image: busybox:1.36
          command: [sleep, "3600"]
          resources: { requests: { cpu: "6", memory: 32Mi }, limits: { memory: 64Mi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: ml-job }
spec:
  selector: { matchLabels: { app: ml-job } }
  template:
    metadata: { labels: { app: ml-job } }
    spec:
      nodeSelector: { accelerator: nvidia }
      containers:
        - name: job
          image: busybox:1.36
          command: [sleep, "3600"]
          resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 32Mi } }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: reports-data }
spec:
  storageClassName: fast-ssd
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 256Mi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: reports }
spec:
  selector: { matchLabels: { app: reports } }
  template:
    metadata: { labels: { app: reports } }
    spec:
      containers:
        - name: reports
          image: busybox:1.36
          command: [sh, -c, 'date > /data/started; sleep 3600']
          volumeMounts: [{ name: data, mountPath: /data }]
          resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 32Mi } }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: reports-data }
EOF
echo "Deployments batch, ml-job and reports in $NS are deployed. Their pods are Pending."
