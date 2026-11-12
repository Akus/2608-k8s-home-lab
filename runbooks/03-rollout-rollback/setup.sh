#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
NS=rb-03
ensure_ns $NS

kubectl -n $NS apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
  annotations: { kubernetes.io/change-cause: "v1: first release" }
spec:
  replicas: 3
  progressDeadlineSeconds: 60
  strategy: { rollingUpdate: { maxUnavailable: 0, maxSurge: 1 } }
  selector: { matchLabels: { app: shop } }
  template:
    metadata: { labels: { app: shop } }
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          env: [{ name: GREETING, value: v1 }]
          resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 64Mi } }
EOF
kubectl -n $NS rollout status deploy/shop --timeout=180s >/dev/null

kubectl -n $NS set env deploy/shop GREETING=v2 >/dev/null
kubectl -n $NS annotate deploy/shop kubernetes.io/change-cause="v2: new greeting" --overwrite >/dev/null
kubectl -n $NS rollout status deploy/shop --timeout=180s >/dev/null

kubectl -n $NS set image deploy/shop nginx=nginx:1.27-alpne >/dev/null
kubectl -n $NS annotate deploy/shop kubernetes.io/change-cause="v3: nginx bump" --overwrite >/dev/null

echo "Release v3 of deployment shop (namespace $NS) is rolling out. Over to you."
