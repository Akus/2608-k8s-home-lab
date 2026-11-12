# 02: Run Postgres with persistent storage

No setup script. Create namespace `rb-02` yourself.

## Task

1. Secret `db-credentials` in `rb-02` with key `POSTGRES_PASSWORD`.
2. StatefulSet `db`, 1 replica, image `postgres:16-alpine`. The password comes from the
   Secret, **not** from a literal value in the StatefulSet.
3. Its data lives on a 1Gi PersistentVolumeClaim from a `volumeClaimTemplate` (StorageClass
   `local-path`, the cluster default).
4. A headless Service `db` (`clusterIP: None`) on port 5432.
5. In the database, create table `notes` and insert at least one row.

`verify.sh` checks the table, **deletes pod `db-0`**, waits for the StatefulSet to bring it
back, and checks the rows are still there.

```bash
./verify.sh
./cleanup.sh   # also deletes the PVC: StatefulSets keep their PVCs when deleted
```

Questions to answer for yourself afterwards:
- Which node did `db-0` land on, and where on that node's disk is the data?
  (`kubectl get pv -o yaml`, look at `nodeAffinity` and `hostPath`.)
- What happens to `db-0` if that node goes down? (Scenario 20 tries it.)

<details><summary>Hints</summary>

- `kubectl create secret generic db-credentials --from-literal=POSTGRES_PASSWORD=...`
- `env[].valueFrom.secretKeyRef`, or `envFrom` with a `secretRef`.
- The postgres image refuses to initialise into a non-empty directory. Set `PGDATA` to a
  subdirectory of the mount, e.g. `/var/lib/postgresql/data/pgdata`.
- `kubectl -n rb-02 exec -it db-0 -- psql -U postgres`: the local socket needs no password.

</details>

<details><summary>Solution</summary>

```bash
kubectl create namespace rb-02
kubectl -n rb-02 create secret generic db-credentials --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)"
```

```yaml
apiVersion: v1
kind: Service
metadata: { name: db, namespace: rb-02 }
spec:
  clusterIP: None
  selector: { app: db }
  ports: [{ port: 5432 }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: db, namespace: rb-02 }
spec:
  serviceName: db
  replicas: 1
  selector: { matchLabels: { app: db } }
  template:
    metadata: { labels: { app: db } }
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: db-credentials, key: POSTGRES_PASSWORD } }
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports: [{ containerPort: 5432 }]
          readinessProbe:
            exec: { command: [pg_isready, -U, postgres] }
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        resources: { requests: { storage: 1Gi } }
```

```bash
kubectl -n rb-02 exec db-0 -- psql -U postgres -c \
  "CREATE TABLE notes (id serial PRIMARY KEY, body text); INSERT INTO notes (body) VALUES ('hello');"
```

The PVC is called `data-db-0`: one per replica, named `<template>-<statefulset>-<ordinal>`.
A re-created `db-0` gets the same PVC back, which is the whole point of a StatefulSet.

</details>
