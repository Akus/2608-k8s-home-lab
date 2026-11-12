# Teachings

Notes on how this lab's pieces actually work, written against the running cluster rather than
in the abstract. Companions: [LAKEHOUSE.md](LAKEHOUSE.md) for how the data stack is built,
[IMPLEMENTATION.md](IMPLEMENTATION.md) for how the cluster was built,
[runbooks/](runbooks/) for practising on it.

---

## Iceberg, Spark and DuckDB

### The one-sentence version

**Iceberg is a file format. Spark and DuckDB are engines that read it.** Confusing them is the
most common mistake, and runbook [43](runbooks/43-duckdb-connection/) exists to poke at it.

### Iceberg

Before table formats, a "data lake" was Parquet files in a bucket plus a convention. That
breaks in specific ways: you cannot tell which files belong to the table *right now*, two
writers corrupt each other, renaming a column silently nulls history, and `SELECT count(*)`
has to list the whole bucket.

Iceberg fixes it by adding **metadata that lists the files**:

```
catalog (iceberg-rest:8181)      "the current table is → vN.metadata.json"
   └─ vN.metadata.json           schema, partition spec, snapshot list
        └─ snapshot              one per write
             └─ manifest list
                  └─ manifests   file paths + per-column min/max stats
                       └─ *.parquet   ← in Garage
```

Three consequences worth knowing:

**Snapshots.** Every write appends a new snapshot instead of mutating. That is why runbook
[41](runbooks/41-time-travel-rollback/)'s rollback works, and why this table had **4 snapshots
for 8 rows** when measured — snapshot count tracks *writes*, not data. It is also why
compaction frees no space until `expire_snapshots` runs: the old snapshots still reference the
old files.

**Field IDs.** Columns are tracked by integer, not by name or position. So `ADD`, `DROP` and
`RENAME` are metadata-only edits — runbook [40](runbooks/40-schema-evolution/) adds a column to
months of history in milliseconds, and old files simply read as NULL. This kills the classic
lake outage: *"we renamed a column and every historical file went null."*

**Atomic commits.** A writer commits by asking the catalog to swap the metadata pointer,
conditional on nobody else having moved it. That single atomic operation is the entire basis of
safe concurrency — and the reason the catalog is not optional bookkeeping.

What Iceberg explicitly does **not** do: execute queries. It has no compute. Hence engines.

### Spark

A distributed compute engine, and Iceberg's reference implementation — new Iceberg features
land in Spark first.

Here it runs `local[2]`: one pod, no executors. Every query costs ~60–90s of JVM startup,
which is why `runbooks/lakehouse-sql.sh` feels sluggish. That cost is fixed and irrelevant for
a scheduled job, and intolerable for exploration.

What only Spark can do in this lab:

- **Write** — `writeTo().append()`, and `MERGE INTO` for idempotent upserts (`report.py`)
- **Maintain** — `rewrite_data_files`, `expire_snapshots`, `remove_orphan_files` (runbook 32)
- **Inspect metadata** — `.snapshots`, `.files`, `.history`

### DuckDB

SQLite's shape, for analytics: in-process, single binary, no server, vectorized columnar
execution. It reads Iceberg through an extension.

What it is superb at: `SELECT ... ORDER BY recorded_at DESC LIMIT 10` returns instantly,
straight from Garage. No cluster, no JVM.

What it cannot do:

```sql
SELECT * FROM lake.ops.node_samples.snapshots;
-- Parser Error: NameListToString NOT IMPLEMENTED

CALL lake.system.rewrite_data_files('ops.node_samples');
-- Catalog Error: Table Function with name rewrite_data_files does not exist!
```

It cannot even *parse* a metadata-table name. Not a missing feature — those tables and the
`system.*` procedures are **engine** implementations, not part of the format.

### The actual point

```
                 ┌─ Spark    → writes, MERGE, compaction, expiry, metadata
one copy of  ────┤
data in Garage   └─ DuckDB   → fast interactive reads
```

**Multiple engines, one copy of the data, no ETL between them.** That is the whole pitch of a
table format, and this lab demonstrates it literally: Spark wrote the rows, DuckDB read the
same bytes, nothing was copied or converted.

It is also why a vendor-specific catalog (AWS Glue) was rejected for this project: it
re-couples you to one ecosystem and throws the portability away. See LAKEHOUSE.md §9.

### Three things to remember

1. **Format ≠ engine.** When a tool claims "Iceberg support", ask *which half* — reading
   manifests is easy; compaction, expiry and safe concurrent writes are where engines differ.
2. **Snapshots are the unit of change.** Time travel and rollback are free; the cost is
   retention, which is a recovery-window decision disguised as a cleanup setting.
3. **Compaction and expiry are separate jobs with separate risks.** One makes queries fast,
   the other reclaims space and destroys your ability to roll back.

Hands-on order: **43** (get a prompt) → **40** (metadata-only DDL) → **41** (snapshots and
rollback) → **32** (why maintenance exists).

---

## What is running in this environment

Everything below is live on the cluster unless marked otherwise. Versions are what the pods
actually report, not what a chart claims.

### Kubernetes platform

| Component | Version | What it does |
|---|---|---|
| kube-apiserver, kube-scheduler, kube-controller-manager | v1.31.14 | The control plane. Static pods on `k8s-cp-1`, managed by kubelet from `/etc/kubernetes/manifests`, not by Kubernetes itself. |
| etcd | 3.5.24 | The only stateful part of the control plane — all cluster state. Back it up (runbook 21); nothing else recovers it. |
| kubelet + containerd | 1.31.14 / 2.2.1 | Node agents. Not pods — systemd units on each Pi. containerd runs containers; kubelet decides which. |
| kube-proxy | v1.31.14 | Programmes iptables so a Service ClusterIP load-balances to its pods. |
| CoreDNS | v1.11.3 | Cluster DNS. `garage.lakehouse` resolves because of this. |
| Calico | v3.28.0 | CNI — gives every pod a routable IP and enforces NetworkPolicy. If it breaks, the cluster loses networking including whatever would fix it. |
| metrics-server | v0.7.2 | Serves `metrics.k8s.io`, which is what `kubectl top` and the Spark ingest job read. |
| local-path-provisioner | v0.0.30 | The StorageClass. Binds a PVC to a directory on one node's SSD — so **a PVC pins its pod to that node**, and there is no `ReadWriteMany`. |
| MetalLB | v0.14.8 | Hands out LoadBalancer IPs from `192.168.1.240-250` on bare metal, where no cloud provider exists to do it. |
| ingress-nginx | v1.11.2 | The single HTTP entry point on `192.168.1.240`. Routes by hostname. Resolves duplicate hosts in favour of the **oldest** Ingress — worth remembering. |
| cert-manager | v1.21.2 | Issues TLS certificates. Let's Encrypt via Route53 DNS-01 is configured but not finished (TODO.md). |

### GitOps and CI

| Component | Version | What it does |
|---|---|---|
| Argo CD | v3.6.1 | Reconciles three Applications (`jenkins`, `lakehouse`, `monitoring`) from this repo. `application-controller` compares and syncs, `repo-server` renders manifests, `server` is the API/UI, `redis` caches. `dex`, `notifications` and `applicationset` exist at **0 replicas** — unused, kept so an upgrade stays a tag bump. |
| Jenkins | 2.580.2-lts | This project's own controller in `ci`, configured entirely by JCasC. Runs four lakehouse pipelines on cron. Builds nothing itself (`numExecutors: 0`). |
| Jenkins agents | inbound-agent 3395 | Ephemeral pods spawned per build by the Kubernetes plugin, capped at 2 concurrent. They do not run Spark — they create a Kubernetes Job and follow its logs. |

### Lakehouse

| Component | Version | What it does |
|---|---|---|
| Garage | v2.5.0 | S3-compatible object store — the "disk" the Iceberg data files live on. Single node, `replication_factor 1`. Reached as `garage:3900`. |
| Iceberg REST catalog | 1.10.1 | Answers "which files make up this table?" and performs the atomic commit swap. Backed by SQLite on a PVC. Vendor-neutral, so it ports to AKS. |
| Spark | 3.5.9 | Not a running service — an ephemeral Job per pipeline run, `local[2]`, with the Iceberg jars pulled at submit time and cached on the `spark-ivy-cache` PVC. |
| Tables | — | `lake.ops.node_samples` (bronze, 15 min), `weather` (bronze, hourly), `node_hourly` (silver, MERGE INTO), `thermal_daily` (gold). |

### Monitoring

| Component | Version | What it does |
|---|---|---|
| Prometheus | v3.6.0 | Scrapes 7 jobs via Kubernetes service discovery, 15d retention. Reload with `kill -HUP 1`, **not** `wget .../-/reload` — that silently does nothing in this image. |
| Grafana | 12.3.0 | Dashboards on `dash.home.lan`. Datasource and dashboards are provisioned from files, so the PVC holds nothing that matters. Anonymous Viewer is enabled. |
| node-exporter | v1.9.1 | DaemonSet, host network. The only source of **SoC temperature** and throttling state — the metric this lab was built around. |
| kube-state-metrics | v2.17.0 | Turns API-server object state into metrics: pod restarts, replica mismatches, PVC usage. Complements node-exporter, which sees the host but not the cluster. |

### Chaos

| Component | Version | What it does |
|---|---|---|
| LitmusChaos operator | 3.31.0 | Runs `ChaosEngine` CRs as fault injections. Scoped `WATCH_NAMESPACE=hil-lab`, so while hil-lab is parked it has **nothing to target**. No ChaosCenter: its MongoDB needs ARMv8.2 and the Pi 4 is ARMv8.0. |

### Parked — the 2609 project

| Component | State | What it was |
|---|---|---|
| `hil-lab` namespace | **8 Deployments at 0 replicas** | The HIL test-rig lab from `2609-Java-Jenkins-CICD-for-Siemens-test-rigs`: `rig-api` plus three simulated rigs, its own Jenkins, Grafana and Prometheus. Stopped 2026-11-12 — its Jenkins was pegging a full core and crash-looping, and this project has its own now. All six PVCs retain their data. Restore with `kubectl -n hil-lab scale deploy --all --replicas=1`. |

### Web UIs

All on `192.168.1.240`; add to the **Windows** hosts file (WSL regenerates its own).

| URL | What |
|---|---|
| `argocd.home.lan` | Argo CD — sync state of the three Applications |
| `ci.home.lan` | Jenkins — the four lakehouse pipelines |
| `dash.home.lan` | Grafana — the `Home lab` dashboard |
| `metrics.home.lan` | Prometheus — target health and ad-hoc PromQL |
| `jenkins/grafana/prometheus/rig-api.home.lan` | the parked 2609 stack; these return nothing |
