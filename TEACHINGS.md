# Teachings

Notes on how this lab's pieces actually work, written against the running cluster rather than
in the abstract. Companions: [LAKEHOUSE.md](LAKEHOUSE.md) for how the data stack is built,
[IMPLEMENTATION.md](IMPLEMENTATION.md) for how the cluster was built,
[runbooks/](runbooks/) for practising on it.

1. [Iceberg, Spark and DuckDB](#iceberg-spark-and-duckdb) — how the data stack works
2. [What is running in this environment](#what-is-running-in-this-environment) — every
   component and what it does
3. [Gotchas](#gotchas) — the traps, each with symptom, cause and fix. **Start here when
   something is behaving oddly**; most of them report a symptom several layers above the cause.

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

---

## Gotchas

Every one of these cost real debugging time while building this environment. Grouped by where
they bite, each as symptom → cause → fix. Most share a shape: **the error names a symptom
several layers above the cause.**

### Kubernetes and kustomize

**A generated ConfigMap lands in the wrong namespace.** Pod sits in `Init` with
`configmap "jenkins-casc" not found`, while `kubectl get cm -A` shows it in `default`.
`configMapGenerator` output gets no namespace unless the Kustomization sets `namespace:` —
even when every hand-written resource in the same directory names one explicitly. Set
`namespace:` at the top. Cluster-scoped kinds like `Namespace` are correctly left alone.

**`local-path` pins a pod to a node and has no `ReadWriteMany`.** A PVC is a directory on one
node's SSD, so whatever mounts it can only ever schedule there. This is the reason the
lakehouse keeps data in object storage rather than a shared volume, and why Garage's StatefulSet
is anchored to one node whether you intended it or not.

**ingress-nginx resolves a duplicate host in favour of the OLDEST Ingress.** Two Ingresses
claiming `grafana.home.lan` do not conflict loudly — the older one silently keeps the traffic
and your new deployment looks broken. Check `kubectl get ingress -A` for the hostname before
reusing it. This is why monitoring is on `dash.home.lan` / `metrics.home.lan`.

**Applying the workloads is not the same as applying the Argo `Application`.** Running
`kubectl apply -k clusters/home-lab/monitoring` gets the stack running but unmanaged; the
Application CRs live in `clusters/home-lab/argocd/apps`. Everything looks right, which is the
problem — verify with `kubectl -n argocd get applications`, not by looking at pods.

**An Argo app whose git path does not exist reports `ComparisonError`, not a sync.** Useful
rather than annoying: with sync status `Unknown` it will **not** prune, so hand-applied
resources survive until the manifests are actually pushed.

### Container images

**An image with no `ENTRYPOINT` ignores your intent if you only set `args`.**
`dxflrs/garage` has `CMD ["/garage","server"]` and no entrypoint, so `args: ["server"]` alone
makes Kubernetes exec `server` as the binary:
`exec: "server": executable file not found in $PATH`. Set both `command` and `args`, or neither.
Check with the registry config blob before guessing.

**Registries change.** `bitnami/kubectl` returns NOT FOUND after Bitnami's 2025 registry
change; MinIO now gates anonymous manifest inspection. Verify an image exists and publishes
`linux/arm64` before writing a manifest around it — on this cluster that check is not optional.

### Jenkins

**JCasC copied from an older Jenkins can be invalid.** `excludeClientIPFromCrumb` was removed
from `DefaultCrumbIssuer`; the controller exits with code **5** and the real cause is one
`SEVERE` line far above the shutdown stack trace:
`UnknownAttributesException: Invalid configuration elements for type ... DefaultCrumbIssuer`.
Grep `--previous` logs for `SEVERE`, not for the stack.

**Job DSL binds interpolated job names lazily.** A loop with
`pipelineJob("lakehouse-${suffix}")` creates **one** job named `lakehouse-` with an empty
suffix. Write the blocks out explicitly, or concatenate strings — explicit beats clever in
config you read more often than you write.

**Jobs created by JCasC appear after `Loaded all jobs`.** They are on disk and logged as
`createOrUpdateConfig for <name>`, but absent from `/api/json` until the controller restarts.
If the log says it created them and the API disagrees, restart before debugging the DSL.

**Plugin install on an emptyDir costs ~3 minutes per restart.** Deliberate here — it keeps
`plugins.txt` authoritative instead of letting a stale PVC copy shadow it — but if restart time
starts to matter, move that volume to a PVC.

### `kubectl logs -f`

**Following logs on a pod that has not started returns immediately with an error.**

```
error: container "spark" in pod "..." is waiting to start: ContainerCreating
```

It does not wait. Any script that pipes `logs -f` and then reads `.status.succeeded` will see an
unfinished job and conclude failure. This bit twice — `Jenkinsfile.lakehouse` and
`runbooks/lakehouse-sql.sh`. Wait for the pod to leave `Pending` first, then follow, then poll
for a terminal state. And never delete the Job on the failure path: the pod and its logs are
the only evidence.

### Prometheus and Grafana

**`wget -qO- .../-/reload` does not POST in the prom image.** The hot reload silently no-ops,
leaving a config that is correct on disk and stale in memory — so you debug a file that is not
the one running. Use `kubectl -n monitoring exec deploy/prometheus -- kill -HUP 1`, and verify
with `/api/v1/status/config` rather than by reading the mounted file.

**Filter scrape targets by endpoint PORT name, not service name.**
`argocd-repo-server` exposes `server:8081` (gRPC) beside `metrics:8084`; selecting the service
scrapes both and reports 404s and timeouts. Filtering on
`__meta_kubernetes_endpoint_port_name` also self-limits to what is actually running, since
components at 0 replicas have no endpoints.

**Grafana assigns a random datasource uid unless you pin it.** Dashboards reference datasources
by uid, so a provisioned dashboard renders every panel empty against an auto-generated
`PBFA97CFB590B2093`. Set `uid:` in the datasource provisioning and use it in the dashboard JSON.

**Grafana cannot change a datasource uid in place.** Pinning it afterwards crash-loops the pod:
`Datasource provisioning error: data source not found`. Add `deleteDatasources:` for the same
name so provisioning deletes then recreates — which also makes any future uid or type change
safe.

### Iceberg and S3-compatible storage

**AWS SDK v2 ≥ 2.30 adds flexible checksums to every PUT, and non-AWS stores reject them.**
Garage answers `Invalid payload signature`, surfaced through two layers as
`ServiceFailureException: Server error: InvalidRequestException`. The fix is SDK-level, not
Iceberg-level, and applies to MinIO and Ceph too:

```
AWS_REQUEST_CHECKSUM_CALCULATION=when_required
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
```

**Garage needs path-style addressing.** `s3.path-style-access=true` for Spark,
`URL_STYLE 'path'` for DuckDB. Its region is the literal string `garage` from `garage.toml`,
not an AWS region.

**A three-tier failure reports itself at the top.** Spark says the catalog 500'd, the catalog
says Garage returned 403, Garage says the access key is unknown. Every layer above the broken
one reports "the thing below me failed" — always walk down. This is the whole point of runbook
[30](runbooks/30-lakehouse-s3-auth/).

**Changing a Secret does not restart pods that mounted it as env vars.** `iceberg-rest` keeps
the old credentials until `rollout restart`. Spark Jobs pick up the new value by themselves,
because each run is a new pod.

### DuckDB

**DuckDB 2.0 binaries require AVX2.** This workstation's i5-2520M (Sandy Bridge) has AVX but not
AVX2, so 2.0 dies with `Illegal instruction (core dumped)` — and on Windows closes with no
message at all. **v1.5.6** is the last line that runs here. Check with
`grep -o -m1 avx2 /proc/cpuinfo`.

**DuckDB assumes an Iceberg REST catalog uses OAuth2.** An unauthenticated catalog is legal in
the spec but not the default assumption: `AUTHORIZATION_TYPE is 'oauth2', yet no 'secret' was
provided`. Pass `AUTHORIZATION_TYPE 'none'` explicitly.

**The two endpoints take different forms.** The S3 `ENDPOINT` takes **no** scheme
(`127.0.0.1:3900`); the catalog `ENDPOINT` **requires** one (`http://127.0.0.1:8181`).

**Metadata tables and `system.*` procedures are engine features, not format features.** DuckDB
cannot parse `lake.ops.node_samples.snapshots` at all, and has no `rewrite_data_files`. Reading
is the easy half — see the format-vs-engine section above.

### Workstation (WSL2)

**WSL's `/etc/hosts` is auto-generated from the Windows one on every start.** Editing it is
pointless. Lab hostnames go in `C:\Windows\System32\drivers\etc\hosts`, which needs
Administrator rights and is read-only from WSL. `wsl --shutdown` makes new entries resolve
inside WSL too.

**Ports forwarded in WSL are reachable from Windows on `127.0.0.1`.** WSL2 relays listening
sockets to the host, so `kubectl port-forward` in WSL is enough for a Windows SQL client — no
`--address 0.0.0.0` needed.
