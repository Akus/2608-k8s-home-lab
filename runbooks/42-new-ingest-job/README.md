# 42: Ship a new dataset end to end

> **Developer scenario.** You add a table, a job and a pipeline. Everything you create lives
> under `lake.dev`, so nothing the other scenarios use is at risk.

No `setup.sh` — this one is build, not break.

## Situation

You want to know whether the cluster's pods are churning: how many exist, how many are
restarting, and how that tracks against the node telemetry already being collected. Nobody
has built it, and the platform gives you everything you need.

## Task

Add a third bronze table and the job that fills it, following the shape of the two that exist:

1. **Table** `lake.dev.pod_counts`, partitioned by day, with at least:
   `namespace STRING, pods INT, restarts INT, recorded_at TIMESTAMP`
2. **Job** `clusters/home-lab/lakehouse/spark/ingest_pods.py`, reading the Kubernetes API and
   appending one row per namespace.
3. **Deploy** it so the script lands in the `spark-scripts` ConfigMap.
4. **Run** it and confirm rows arrive.
5. **Schedule** it as a fifth Jenkins pipeline.

Constraint: the Spark pod's ServiceAccount is `spark`, and its RBAC is deliberately minimal.
Find out what it can actually see before you write the collector.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- Read `ingest_samples.py` first — `lakehouse_common.py` already has `k8s_get()`, which handles
  the ServiceAccount token and CA for you.
- `kubectl -n lakehouse auth can-i list pods --as=system:serviceaccount:lakehouse:spark`.
  What does that return, and why? Look at `clusters/home-lab/lakehouse/rbac.yaml`.
- You will need to extend the ClusterRole. Add the smallest rule that does the job, and say in
  a comment why it is needed.
- Scripts reach the pod through `configMapGenerator` in `spark/kustomization.yaml`. A new file
  is not deployed until it is listed there.
- Adding a pipeline is one more `- script:` block in
  `clusters/home-lab/jenkins/jenkins.yaml`. The Jenkinsfile derives the script name from the
  job name — `lakehouse-ingest-pods` → `ingest_pods.py`. Name it accordingly and you write no
  pipeline code at all.

</details>

<details><summary>Solution</summary>

**RBAC first.** `spark` can read nodes and metrics, not pods:

```bash
kubectl auth can-i list pods --as=system:serviceaccount:lakehouse:spark -A   # no
```

In `clusters/home-lab/lakehouse/rbac.yaml`, add to `lakehouse-telemetry-reader`:

```yaml
  # ingest_pods.py counts pods and restarts per namespace. List-only, no read of
  # pod contents, logs or secrets.
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
```

**The job**, `spark/ingest_pods.py`:

```python
from datetime import datetime, timezone
from collections import defaultdict
from pyspark.sql import functions as F
import lakehouse_common as lc

TABLE = f"{lc.CATALOG}.dev.pod_counts"

def main() -> int:
    spark = lc.spark_session("lakehouse-ingest-pods")
    spark.sql(f"CREATE NAMESPACE IF NOT EXISTS {lc.CATALOG}.dev")
    spark.sql(f"""
        CREATE TABLE IF NOT EXISTS {TABLE} (
            namespace STRING, pods INT, restarts INT, recorded_at TIMESTAMP
        ) USING iceberg PARTITIONED BY (days(recorded_at))""")

    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    pods, restarts = defaultdict(int), defaultdict(int)
    for p in lc.k8s_get("/api/v1/pods")["items"]:
        ns = p["metadata"]["namespace"]
        pods[ns] += 1
        restarts[ns] += sum(c.get("restartCount", 0)
                            for c in p["status"].get("containerStatuses", []))

    rows = [{"namespace": ns, "pods": n, "restarts": restarts[ns], "recorded_at": now}
            for ns, n in sorted(pods.items())]
    df = spark.createDataFrame(rows).select(
        F.col("namespace").cast("string"), F.col("pods").cast("int"),
        F.col("restarts").cast("int"), F.to_timestamp("recorded_at").alias("recorded_at"))
    df.writeTo(TABLE).append()
    print(f"appended {df.count()} namespace row(s)")
    spark.sql(f"SELECT * FROM {TABLE} ORDER BY restarts DESC LIMIT 10").show(truncate=False)
    spark.stop()
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

**Deploy and run:**

```bash
# add ingest_pods.py to the files: list in spark/kustomization.yaml, then
kubectl apply -k clusters/home-lab/lakehouse
sed -e 's/__JOB__/rb42-pods/' -e 's/__SCRIPT__/ingest_pods.py/' \
  ../../clusters/home-lab/lakehouse/spark/spark-job.yaml | kubectl apply -f -
kubectl -n lakehouse logs -f job/rb42-pods
```

**Schedule it** by copying one `- script:` block in `jenkins.yaml`, renaming the job to
`lakehouse-ingest-pods` and picking a cron. No Jenkinsfile change: the pipeline maps the job
name to the script name itself.

Then the payoff — your new table joined against the existing telemetry:

```sql
SELECT date_trunc('HOUR', p.recorded_at) AS hour,
       SUM(p.restarts) AS restarts,
       ROUND(AVG(n.temp_c), 1) AS avg_pi_temp
FROM lake.dev.pod_counts p
JOIN lake.ops.node_samples n
  ON date_trunc('HOUR', p.recorded_at) = date_trunc('HOUR', n.recorded_at)
GROUP BY 1 ORDER BY 1 DESC;
```

The thing to notice: adding a dataset touched one RBAC rule, one Python file, one line of
kustomize and one block of Jenkins config. No new infrastructure, no new storage, no catalog
migration. That is what the platform is *for* — and it is a fair benchmark for any data
platform you are asked to evaluate.

</details>
