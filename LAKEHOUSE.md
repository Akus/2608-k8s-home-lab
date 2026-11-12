# Lakehouse — Argo CD + Spark + Iceberg on the Pi cluster

A small data platform that watches the cluster it runs on. Every 15 minutes it records each
Pi's CPU, memory and SoC temperature; hourly it records the outdoor weather; nightly it rolls
both up and compacts the tables. The question it exists to answer: **does a warm room actually
throttle the Pis?**

It is also the GitOps layer. Argo CD replaced the Flux plan (`FLUX-MIGRATION-PLAN.md`, removed
2026-11-12) — Flux was never installed, so there was nothing to migrate and no second
controller to collide with.

## Shape

```
Jenkins (ns: ci) ──spawns──> agent pod ──creates──> Kubernetes Job ──> Spark local[2]
                                                   (ns: lakehouse)        │
                                     ┌────────────────────┬───────────────┴────┐
                                     ▼                    ▼                    ▼
                            iceberg-rest:8181      garage:3900          kubernetes API
                            (catalog, SQLite)      (S3, data files)     + node-exporter:9100
```

Self-contained: nothing here depends on the `2609-Java-Jenkins-CICD-for-Siemens-test-rigs`
repo or the `hil-lab` namespace. This project runs its own Jenkins.

| Component | Why it is this and not something else |
|---|---|
| **Garage** | S3-compatible store. Iceberg wants object storage, and the cluster has only `local-path` (no RWX), so this is what makes data shareable between pods. Picked over MinIO: public arm64 manifests, far lighter, no console licensing mess. |
| **Iceberg REST catalog** | Vendor-neutral, unlike AWS Glue — so it ports to the AKS side. SQLite on a PVC as its store, which keeps the image stock and drops a whole Postgres pod. Single writer, which is what this lab has. |
| **Spark `local[2]`** | One pod, no executors, no shuffle service. Right for kilobytes a day. Moving to cluster mode changes only `--master`. |
| **node-exporter** | The only way to see SoC temperature and throttling. `TODO.md` wanted it for Prometheus anyway. |
| **Jenkins** | This project's own controller in `ci`, stock image, configured entirely by JCasC. Build agents are ephemeral pods via the Kubernetes plugin, so nothing permanent idles. |
| **Argo CD** | Syncs `jenkins`, `lakehouse` and `node-exporter` from this repo. |

Everything is pinned and verified multi-arch for arm64: Argo CD `v3.6.1`, `dxflrs/garage:v2.5.0`,
`apache/iceberg-rest-fixture:1.10.1`, `spark:3.5.9-scala2.12-java17-python3-ubuntu`,
`quay.io/prometheus/node-exporter:v1.9.1`, `jenkins/jenkins:2.580.2-lts-jdk21`,
`jenkins/inbound-agent:3395.v6e5377b_0fb_3c-5-jdk21`, Iceberg runtime `1.11.0`.

## 1. Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply --server-side -k clusters/home-lab/argocd
kubectl -n argocd rollout status deploy/argocd-server

# initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Add `argocd.home.lan` to your hosts file / router DNS pointing at `192.168.1.240`, like the
other lab UIs. Then register the two apps:

Create the two hand-made Secrets first — same rule as `cert-manager/route53-credentials`,
never committed:

```bash
kubectl create namespace ci
kubectl -n ci create secret generic jenkins-admin \
  --from-literal=JENKINS_ADMIN_ID=admin \
  --from-literal=JENKINS_ADMIN_PASSWORD='<pick one>'
```

```bash
kubectl apply -k clusters/home-lab/argocd/apps
kubectl -n argocd get applications
```

Argo syncs `node-exporter` and `jenkins` cleanly. **`lakehouse` goes Healthy except for
`iceberg-rest`, which stays in `CreateContainerConfigError` until step 2** — it needs the S3
credentials that do not exist yet. That is expected, not a failure.

Jenkins takes a couple of minutes on first boot: an initContainer downloads the plugins from
`plugins.txt` before the controller starts. Watch it with
`kubectl -n ci logs deploy/jenkins -c plugins -f`, then open `ci.home.lan`.

## 2. Bootstrap Garage (one-time)

Garage needs a storage layout assigned before it will serve, and the S3 key has to be created
by Garage itself. Same rule as `cert-manager/route53-credentials`: **the Secret is created by
hand and never committed.**

```bash
G="kubectl -n lakehouse exec garage-0 -- /garage"

# 1. find this node's id (first column of the "HEALTHY NODES" table)
$G status

# 2. give it a zone and capacity, then commit the layout
$G layout assign -z home -c 8G <node-id>
$G layout apply --version 1

# 3. bucket + key
$G bucket create lakehouse
$G key create lakehouse-key          # prints Key ID and Secret key — copy both
$G bucket allow --read --write lakehouse --key lakehouse-key
```

```bash
kubectl -n lakehouse create secret generic lakehouse-s3-credentials \
  --from-literal=access-key-id=<Key ID> \
  --from-literal=secret-access-key=<Secret key>

kubectl -n lakehouse rollout restart deploy/iceberg-rest
kubectl -n lakehouse get pods          # all Running now
```

Verify the catalog is alive:

```bash
kubectl -n lakehouse run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s http://iceberg-rest:8181/v1/config
```

## 3. Run a job by hand

Before wiring Jenkins, check the whole path works:

```bash
sed -e 's/__JOB__/manual-1/' -e 's/__SCRIPT__/ingest_samples.py/' \
  clusters/home-lab/lakehouse/spark/spark-job.yaml | kubectl apply -f -

kubectl -n lakehouse logs -f job/manual-1
```

The first run downloads ~100MB of Iceberg jars from Maven Central onto the `spark-ivy-cache`
PVC and takes several minutes on a Pi. Every later run starts in seconds.

Expected tail:

```
  k8s-cp-1: 619m cpu, 2212Mi mem, 48.3C
  k8s-w-1: 1376m cpu, 2041Mi mem, 51.1C
appended 2 row(s) to lake.ops.node_samples
lake.ops.node_samples: 2 rows across 1 data files
```

Then `report.py` once there is data, and `maintain.py` once there are enough files to compact.

## 4. The pipelines

Nothing to wire — the four jobs are defined by Job DSL inside
`clusters/home-lab/jenkins/jenkins.yaml`, so they exist as soon as Argo syncs Jenkins. All
four run `jenkins/Jenkinsfile.lakehouse` from this repo:

| Job | Schedule | Script | Does |
|---|---|---|---|
| `lakehouse-ingest-samples` | every 15 min | `ingest_samples.py` | bronze: node CPU/mem/temp |
| `lakehouse-ingest-weather` | hourly | `ingest_weather.py` | bronze: Open-Meteo |
| `lakehouse-report` | daily 06:00 | `report.py` | silver `MERGE INTO` + gold + the join |
| `lakehouse-maintain` | nightly 03:00 | `maintain.py` | compaction, expiry, orphans |

Which script runs is derived from the job name, so there are no parameters to keep in sync.
Adding a fifth pipeline is a new `.py` file plus one line in the Job DSL loop.

The pipeline does not run Spark on the agent — it stamps out `spark-job.yaml` as a Kubernetes
Job in `lakehouse` and follows its logs. Spark gets its own pod and its own limits that way,
and the Job survives a controller restart mid-build.

RBAC is in `clusters/home-lab/lakehouse/rbac.yaml` and `clusters/home-lab/jenkins/rbac.yaml`.
The `ci/jenkins` ServiceAccount can reach exactly two namespaces: `ci`, to spawn agent pods,
and `lakehouse`, to run Spark. Nothing cluster-scoped.

## 5. The tables

```
lake.ops.node_samples    bronze   node, cpu_millicores, mem_bytes, temp_c, ready, recorded_at
lake.ops.weather         bronze   location, temp_c, humidity_pct, wind_kmh, observed_at
lake.ops.node_hourly     silver   per node-hour averages (MERGE INTO, so re-runnable)
lake.ops.thermal_daily   gold     peak temp and hours above 70C per node per day
```

70 °C is the throttling threshold from `IMPLEMENTATION.md` §10.

Query them from anywhere that speaks Iceberg REST, or ad-hoc:

```bash
sed -e 's/__JOB__/query-1/' -e 's/__SCRIPT__/report.py/' \
  clusters/home-lab/lakehouse/spark/spark-job.yaml | kubectl apply -f -
```

## 6. Maintenance, and why it is the interesting part

Two rows every 15 minutes means ~96 tiny Parquet files a day. Iceberg does not clean that up
itself, and this is the failure mode every real lakehouse hits:

```
rewrite_data_files    many small files -> few right-sized ones
expire_snapshots      drop old snapshots, releasing their files
remove_orphan_files   sweep files no snapshot references
```

`maintain.py` runs all three and prints file and snapshot counts before and after, so the
effect is visible rather than theoretical. Order matters — expire before the orphan sweep, or
there is nothing to collect. Note `rewrite_data_files` is called with a 32MB target rather
than the 512MB default, which on this data volume would mean "never rewrite anything".

Time travel comes free from the snapshot history:

```sql
SELECT snapshot_id, committed_at, operation FROM lake.ops.node_samples.snapshots;
SELECT COUNT(*) FROM lake.ops.node_samples VERSION AS OF <snapshot_id>;
```

## 7. What this costs

**Measured on the running cluster**, not estimated — `kubectl top pods` right after everything
came up idle:

| Component | Memory |
|---|---|
| Argo CD (4 pods; dex/notifications/appset at 0 replicas) | ~152Mi |
| Jenkins controller | ~310Mi |
| Iceberg REST catalog | ~136Mi |
| Garage (idle; grows with cached data) | ~6Mi |
| node-exporter (2 ×) | ~11Mi |
| **Idle total** | **~615Mi** |
| A Spark job while it runs | +~300Mi, and ~1.5 cores |

That is about a third of what I budgeted before deploying — the JVM services in particular sit
far below their `-Xmx` ceilings when idle. The limits in the manifests are deliberately left
at the higher figures: they are there to contain a bad day, not to describe a normal one.

Against ~10.7GiB free, memory is a non-issue. **CPU is the real constraint**, and it shows:
with one Spark job running, the two nodes sit at roughly 50-60% of 8 cores, and the hil-lab
Jenkins from the 2609 project is still pegged at its own 1-core limit. That is why the Spark
Job requests 500m, the Kubernetes cloud is capped at two concurrent agents, and the crons use
`H` so the four pipelines stagger instead of all firing on the hour.

One honest cost: **Jenkins takes ~3 minutes to restart**, because the plugins initContainer
re-downloads them into an emptyDir each time. That was a deliberate trade — it keeps plugin
upgrades honest and avoids a stale copy on the PVC shadowing `plugins.txt` — but if restart
time starts to matter, move that volume to a PVC.

## 8. Practising on it

Six runbooks in [`runbooks/`](runbooks/) use this stack, split by the role you want to
practise. They follow the same shape as the Kubernetes ones: a situation, a task, and hints
and a solution folded away at the bottom.

| | Platform / DevOps | Developer / data |
|---|---|---|
| | [30](runbooks/30-lakehouse-s3-auth/) Spark fails, nobody changed Spark | [40](runbooks/40-schema-evolution/) Add a column to a live table |
| | [31](runbooks/31-s3-key-rotation/) Rotate S3 credentials, no downtime | [41](runbooks/41-time-travel-rollback/) Roll back a bad write |
| | [32](runbooks/32-iceberg-maintenance/) 400 files, 12 rows | [42](runbooks/42-new-ingest-job/) Ship a new dataset end to end |
| | | [43](runbooks/43-duckdb-connection/) Query it from a SQL client on your desk |

Ad-hoc SQL, for those and for poking around:

```bash
runbooks/lakehouse-sql.sh "SELECT * FROM lake.ops.node_samples ORDER BY recorded_at DESC LIMIT 5"
```

Each call is a fresh Spark pod, so budget ~60-90s per query. That is the honest cost of
local[2] batch jobs instead of a long-lived engine — and the first thing you would replace
with a Thrift server or Trino if this stopped being a lab.

For interactive exploration, skip Spark entirely and point DuckDB at the catalog over a
port-forward — runbook [43](runbooks/43-duckdb-connection/) sets that up. It reads the tables
happily but cannot run Iceberg's `system.*` procedures or query `.snapshots`, because those
belong to the engine rather than the format. Reading is the easy half.

## 9. Moving to real AWS S3

The point of using the S3 API locally is that this is a two-line change, not a rewrite. Spark
and the catalog both use `iceberg-aws-bundle` against Garage exactly as they would against AWS:

1. Delete `spark.sql.catalog.lake.s3.endpoint` from `spark/spark-job.yaml` and
   `CATALOG_S3_ENDPOINT` from `iceberg-rest.yaml`.
2. Replace `lakehouse-s3-credentials` with a real scoped IAM user's key (same pattern as
   `longhorn-backup` in `IMPLEMENTATION.md` §7.1), and set `AWS_REGION` properly.

Worth knowing before you do: every Iceberg metadata read becomes a ~20ms WAN round-trip
instead of a sub-millisecond LAN one, and query planning does many of them. Glue as the
catalog would be the other AWS-native option, but it is AWS-only and this lab's other half is
AKS — which is why the catalog here is REST.
