# Runbooks: hands-on practice on the home lab

Killercoda-style exercises against the real cluster. Each one has a task, a script that checks
your work, and hints and a solution folded away at the bottom of its README.

```bash
cd runbooks/10-pods-not-starting
./setup.sh      # if present: creates the scenario (often a broken one)
# ...work on it with kubectl, ssh, logs, docs...
./verify.sh     # PASS/FAIL per acceptance criterion, run as often as you like
./cleanup.sh    # removes everything the scenario created
```

Rules of the game:
- Don't read `setup.sh` before you're done; it's the answer key for troubleshooting tasks.
- Work from the symptoms: `kubectl get`, `describe`, `logs`, `events`, `journalctl`.
  Official docs (kubernetes.io) are allowed, like in the CKA.
- Practice scenarios live in their own namespace (`rb-NN`) and never touch `hil-lab`,
  `kube-system` or the add-ons. The **real cluster** ones say so at the top; read their
  warnings before starting.

## Build and deploy

| # | Scenario | Skills |
|---|---|---|
| [01](01-deploy-web-app/) | Deploy a web app behind the ingress | Deployment, probes, resources, spread, Service, Ingress |
| [02](02-stateful-postgres/) | Run Postgres with persistent storage | StatefulSet, PVC, Secret, data survives pod loss |
| [03](03-rollout-rollback/) | A bad release is half rolled out | rollout history, undo, change-cause |
| [04](04-rbac-ci-deployer/) | Least-privilege account for a CI pipeline | ServiceAccount, Role, RoleBinding, tokens, kubeconfig |

## Troubleshooting

| # | Scenario | Skills |
|---|---|---|
| [10](10-pods-not-starting/) | Three pods that won't start | ImagePullBackOff, CreateContainerConfigError, OOMKilled |
| [11](11-pods-pending/) | Three pods stuck Pending | scheduling, requests, nodeSelector, StorageClass |
| [12](12-service-no-endpoints/) | Service reachable but nothing answers | selectors, targetPort, readiness, EndpointSlices |
| [13](13-ingress-not-routing/) | Ingress returns 404/503 | IngressClass, backend ports, hosts |
| [14](14-networkpolicy/) | Locked-down namespace, open one path | NetworkPolicy, DNS egress |
| [15](15-hpa-unknown/) | Autoscaler shows `<unknown>` | HPA, metrics-server, requests |
| [16](16-node-notready/) | **Real cluster:** worker is NotReady | kubelet, journalctl, swap |

## Operations

All of these run against the **real cluster**.

| # | Scenario | Skills |
|---|---|---|
| [20](20-drain-node/) | Take the worker down for maintenance | cordon, drain, PDBs, node-local storage |
| [21](21-etcd-backup/) | Back up etcd (and optionally restore) | etcdctl snapshot, static pods |
| [22](22-kubeadm-upgrade/) | Upgrade Kubernetes one minor version | kubeadm upgrade, apt repos, drain order |
| [23](23-certificates/) | Check and renew certificates | kubeadm certs, kubeconfig, cert-manager |
| [24](24-addon-upgrade/) | Upgrade an add-on and roll back | release notes, kubectl diff, patches that get lost |
| [25](25-chaos-game-day/) | Chaos game day + postmortem | Litmus, Grafana, hypotheses, write-up |

## Lakehouse — platform / DevOps role

All of these run against the **real** `lakehouse` namespace (Argo CD + Garage + Iceberg +
Spark, see [LAKEHOUSE.md](../LAKEHOUSE.md)). They are about operating a data platform rather
than Kubernetes primitives: credentials, failure diagnosis across layers, and the maintenance
nobody schedules until it hurts.

| # | Scenario | Skills |
|---|---|---|
| [30](30-lakehouse-s3-auth/) | Spark jobs fail, nobody changed Spark | layered diagnosis, Secrets as env vars, S3 auth |
| [31](31-s3-key-rotation/) | Rotate object-store credentials with no downtime | overlap/switch/verify/revoke, who caches what |
| [32](32-iceberg-maintenance/) | The table has 400 files and 12 rows | compaction, snapshot expiry, orphan files |

## Lakehouse — developer / data role

Same cluster, the other side of the fence: using the platform rather than running it. These
assume no Spark or Iceberg background and build up from a single `ALTER TABLE`.

| # | Scenario | Skills |
|---|---|---|
| [40](40-schema-evolution/) | Add a column to a live table without rewriting | Iceberg field ids, metadata-only DDL |
| [41](41-time-travel-rollback/) | A bad job wrote garbage into the table | snapshots, `VERSION AS OF`, `rollback_to_snapshot` |
| [42](42-new-ingest-job/) | Ship a new dataset end to end | writing a job, least-privilege RBAC, scheduling it |
| [43](43-duckdb-connection/) | Query the lakehouse from a SQL client on your desk | Iceberg REST clients, port-forward, engine vs. format |

### Running SQL against the lakehouse

Most of these need ad-hoc queries. There is no always-on SQL engine — every query is a
one-shot Spark Job, which takes ~60-90s:

```bash
runbooks/lakehouse-sql.sh "SELECT * FROM lake.ops.node_samples ORDER BY recorded_at DESC LIMIT 5"
runbooks/lakehouse-sql.sh -f my-query.sql
```

Useful starting points:

```sql
SHOW NAMESPACES IN lake;
SHOW TABLES IN lake.ops;
DESCRIBE TABLE lake.ops.node_samples;
SELECT * FROM lake.ops.node_samples.snapshots ORDER BY committed_at DESC;
SELECT * FROM lake.ops.node_samples.files;
```

## Suggested order

Kubernetes first: 01 → 10 → 11 → 12 → 13 → 02 → 03 → 14 → 15 → 04, then the real-cluster
ones. Do 21 (etcd backup) before 22 (upgrade).

For the lakehouse, do 40 before 41 (41's setup writes a row shaped by 40's column), and 32
before 41 if you want to see how expiry limits the rollback window. 30 → 31 is the natural
pair: break it, then learn the order that avoids breaking it. 43 stands alone and is the
cheapest one to start with — it ends with a local SQL prompt on the real tables, which makes
every other lakehouse scenario easier to explore.
