# 40: Add a column to a live table without rewriting it

> **Developer scenario.** Works on the real `lake.ops` tables. Additive and safe — no data is
> deleted, and `cleanup.sh` drops the column again.

No `setup.sh` — you start from the running lakehouse.

## Situation

Product wants to know how much *swap* each node is using, alongside the CPU and memory the
ingest already records. `lake.ops.node_samples` has months of history you must not lose, and
dashboards are reading it right now.

In a Parquet-files-in-a-bucket world this is a rewrite-everything migration. It should not be.

## Task

1. Add a `swap_bytes BIGINT` column to `lake.ops.node_samples`.
2. Keep every existing row queryable, with the new column reading as `NULL` for them.
3. Make `ingest_samples.py` populate it on new rows.
4. Prove old and new rows come back from a single query.

Do not recreate the table. Do not rewrite the existing files.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- `ALTER TABLE ... ADD COLUMN` works on Iceberg and is metadata-only.
- `../lakehouse-sql.sh "DESCRIBE TABLE lake.ops.node_samples"`.
- Iceberg tracks columns by **field id**, not by position or name — this is why adding,
  renaming and reordering are all safe, and why old data files with no such column simply read
  as NULL. Compare `SELECT * FROM lake.ops.node_samples.files` before and after: unchanged.
- The ingest script is in the `spark-scripts` ConfigMap, generated from
  `clusters/home-lab/lakehouse/spark/ingest_samples.py`. Edit the file in git, then
  `kubectl apply -k clusters/home-lab/lakehouse`.
- `/proc/meminfo` has `SwapTotal` and `SwapFree` — but this cluster disables swap (kubelet
  requires it). Reading 0 is the correct answer, and worth confirming rather than assuming.

</details>

<details><summary>Solution</summary>

```bash
../lakehouse-sql.sh "ALTER TABLE lake.ops.node_samples ADD COLUMN swap_bytes BIGINT COMMENT 'swap in use; 0 on this cluster, swap is disabled'"
../lakehouse-sql.sh "DESCRIBE TABLE lake.ops.node_samples"
```

That is the whole migration. It rewrote no data: Iceberg wrote a new metadata file with a new
schema id, and nothing else. Old files have no field id for `swap_bytes`, so reads project
NULL for them.

Then in `clusters/home-lab/lakehouse/spark/ingest_samples.py`, add it to the collector and the
projection — node-exporter already publishes `node_memory_SwapTotal_bytes` and
`node_memory_SwapFree_bytes`:

```python
"swap_bytes": swap_used,          # in collect()
F.col("swap_bytes").cast("bigint"),   # in the select()
```

Then roll it out and run once:

```bash
kubectl apply -k clusters/home-lab/lakehouse
sed -e 's/__JOB__/rb40-ingest/' -e 's/__SCRIPT__/ingest_samples.py/' \
  ../../clusters/home-lab/lakehouse/spark/spark-job.yaml | kubectl apply -f -
kubectl -n lakehouse wait --for=condition=complete --timeout=300s job/rb40-ingest
```

```sql
SELECT recorded_at, node, swap_bytes FROM lake.ops.node_samples ORDER BY recorded_at;
-- old rows: NULL.  new rows: a number.  One query, one table, no migration window.
```

What makes this safe is field ids. A column is identified by an integer that never changes, so
`ADD`, `DROP`, `RENAME` and reorder are all metadata operations, and a reader that does not
know about a column simply does not project it. The failure mode this removes — "we renamed a
column and every historical Parquet file silently returned nulls" — is the single most common
data-lake outage there is.

</details>
