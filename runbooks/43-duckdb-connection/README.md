# 43: Query the lakehouse from a SQL client on your desk

> **Developer scenario.** Read-only against the live `lake.ops` tables. Nothing is deployed and
> nothing is exposed permanently — the access path you build here lasts as long as your
> terminal does, which is the point.

```bash
./setup.sh
```

## Situation

You want to explore `lake.ops.node_samples` the way you'd explore any other table: a SQL
prompt, fast iteration, no 90-second wait per query. Going through
[`lakehouse-sql.sh`](../lakehouse-sql.sh) means a fresh Spark pod every time — correct for
running a job, miserable for poking at data.

Iceberg is an open table format, so in principle anything that speaks it can read these
tables. In practice there are four traps between you and a working connection.

## Task

Get a local SQL client reading `lake.ops.node_samples` directly from object storage, without
Spark in the path.

Work out for yourself:

1. **Nothing in `lakehouse` is reachable from your workstation.** Confirm that, then find the
   least-permanent way to fix it. Do not add an Ingress.
2. Which **two** endpoints a client needs, and why one is not enough.
3. Why your first `ATTACH` fails even with both endpoints reachable and correct credentials.
4. What Garage needs that real AWS S3 does not.

Then answer the question the exercise exists for: **can this client run runbook
[32](../32-iceberg-maintenance/)'s compaction calls?** Try it and find out.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- `kubectl -n lakehouse get svc` — what are the service types? `kubectl -n lakehouse get
  ingress`?
- `kubectl port-forward` is the temporary answer. Which services and which ports?
  `clusters/home-lab/lakehouse/iceberg-rest.yaml` and `garage.yaml` list them.
- Reading an Iceberg table takes two things: the **catalog** says which files make up the
  table, and **object storage** holds those files. A client needs both.
- DuckDB: `INSTALL iceberg; LOAD iceberg;` then `ATTACH ... (TYPE iceberg, ...)`. Read the
  error from your first attempt literally — it names a setting and its default.
- `CREATE SECRET ... (TYPE s3, ...)`. Garage is not AWS: look at
  `clusters/home-lab/lakehouse/garage.yaml` for `s3_region`, and remember the Spark job sets
  `s3.path-style-access=true` for a reason.
- On Windows the ports land on `127.0.0.1` even though `kubectl` runs in WSL — WSL2 relays
  listening sockets to the Windows host.
- If `duckdb` exits instantly with no message, that is trap zero. Check your CPU:
  `grep -o avx2 /proc/cpuinfo`.

</details>

<details><summary>Solution</summary>

### Trap 0 — the binary may not run at all

DuckDB 2.0 binaries require **AVX2**. This workstation is an Intel i5-2520M (Sandy Bridge,
2011): it has AVX but not AVX2, so 2.0 dies with `Illegal instruction (core dumped)` — or on
Windows, closes with no message at all.

```bash
grep -o -m1 avx2 /proc/cpuinfo || echo "no AVX2 -> use DuckDB v1.5.x"
```

**v1.5.6** is the last line that runs here, and it has everything this exercise needs.

### Trap 1 — nothing is exposed

```
garage         ClusterIP   3900,3903
iceberg-rest   ClusterIP   8181
```

No Ingress, no LoadBalancer. That is deliberate: the catalog is unauthenticated and the S3 keys
grant read *and write*, so neither belongs on the LAN. `port-forward` gives you access scoped
to one terminal:

```bash
kubectl -n lakehouse port-forward svc/iceberg-rest 8181:8181 &
kubectl -n lakehouse port-forward svc/garage       3900:3900 &
```

### Trap 2 — two endpoints, not one

`8181` is the catalog: it answers "which files are in this table?". `3900` is the object store
holding those files. Point a client at only the catalog and every query fails on the read, not
the lookup — a confusing failure, because the table *lists* fine.

### Trap 3 — DuckDB assumes OAuth2

```
Invalid Configuration Error: AUTHORIZATION_TYPE is 'oauth2', yet no 'secret' was provided,
and no client_id+client_secret were provided.
```

The REST spec allows unauthenticated catalogs; DuckDB does not assume one. Say so explicitly
with `AUTHORIZATION_TYPE 'none'`.

### Trap 4 — Garage is not AWS

Two differences, both of which the Spark job also sets:

- `URL_STYLE 'path'` — Garage serves `host/bucket/key`, not `bucket.host/key`
- `USE_SSL false` — plain HTTP inside the cluster

plus `REGION 'garage'`, which is the literal string in `garage.toml`, not a real AWS region.

### The working connection

```sql
INSTALL iceberg; LOAD iceberg;
INSTALL httpfs;  LOAD httpfs;

CREATE SECRET garage (
    TYPE s3,
    KEY_ID '<access-key-id>',
    SECRET '<secret-access-key>',
    REGION 'garage',
    ENDPOINT '127.0.0.1:3900',   -- no scheme
    URL_STYLE 'path',
    USE_SSL false
);

ATTACH 'warehouse' AS lake (
    TYPE iceberg,
    ENDPOINT 'http://127.0.0.1:8181',   -- scheme required here
    AUTHORIZATION_TYPE 'none'
);

SHOW ALL TABLES;
SELECT node, round(temp_c,1) AS temp_c, cpu_millicores, recorded_at
FROM lake.ops.node_samples ORDER BY recorded_at DESC LIMIT 10;
```

Note the asymmetry in trap 4's neighbour: the S3 `ENDPOINT` takes **no** scheme, the catalog
`ENDPOINT` **requires** one. `setup.sh` writes a ready-to-paste `init.local.sql` with your real
credentials filled in (gitignored — it holds live keys).

### The answer to the real question

**No — DuckDB cannot run runbook 32's maintenance.** Try it:

```sql
SELECT * FROM lake.ops.node_samples.snapshots;
-- Parser Error: NameListToString NOT IMPLEMENTED

CALL lake.system.rewrite_data_files('ops.node_samples');
-- Catalog Error: Table Function with name rewrite_data_files does not exist!
```

Neither error mentions Iceberg, which is the tell: DuckDB is not refusing, it has simply never
heard of these. The first dies in the *parser* — it cannot even express a dotted metadata-table
name.

Iceberg's metadata tables (`.snapshots`, `.files`, `.history`) and its `system.*` procedures
are implemented by the **engine**, not the format. DuckDB reads the format; Spark implements the
procedures. So the division of labour is:

| | Use |
|---|---|
| **DuckDB** on your desk | exploring data, real SQL, fast iteration |
| **`lakehouse-sql.sh`** via Spark | metadata tables, compaction, expiry, writes |

That split is worth internalising before you evaluate any "Iceberg-compatible" tool: reading
Parquet through a manifest is the easy half. Compaction, snapshot expiry and safe concurrent
writes are where engines actually differ.

</details>
