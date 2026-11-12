# 41: A bad job wrote garbage into the table

> **Developer scenario.** Writes junk into `lake.ops.node_samples`, then rolls it back using
> Iceberg's own history. Real table, fully reversible — that is the whole point.

```bash
./setup.sh
```

## Situation

Someone tested a change to the ingest job against the production catalog instead of a scratch
namespace. It ran, it "succeeded", and it appended a batch of rows with impossible values —
temperatures in the thousands.

The dashboards now show a spike. The data is in the table. There is no backup.

## Task

1. Find out exactly **which snapshot** introduced the bad rows, and when.
2. Show what the table looked like immediately before it.
3. Roll the table back to that state, so the bad rows are gone and the good history is intact.
4. Do it without `DELETE FROM`.

Point 4 matters: deleting by predicate works, but it assumes you can write a predicate that
catches exactly the bad rows and nothing else. Rolling back makes no such assumption.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- `SELECT * FROM lake.ops.node_samples.snapshots ORDER BY committed_at` — every write is here,
  with its `snapshot_id`, `operation` and `summary`.
- The `summary` map has `added-records`. Which snapshot added an unusual number?
- Read any past state with `SELECT ... FROM t VERSION AS OF <snapshot_id>` or
  `TIMESTAMP AS OF '<time>'`.
- `CALL lake.system.rollback_to_snapshot(table => 'ops.node_samples', snapshot_id => <id>)`.
- Rolling back is itself a new snapshot. You can roll back the rollback.

</details>

<details><summary>Solution</summary>

```bash
# 1. find the culprit — it added far more records than a normal 2-row ingest
../lakehouse-sql.sh "
SELECT snapshot_id, committed_at, operation, summary['added-records'] AS added
FROM lake.ops.node_samples.snapshots ORDER BY committed_at DESC LIMIT 10"

# 2. look at the table as of the snapshot BEFORE it
../lakehouse-sql.sh "
SELECT COUNT(*) AS rows, MAX(temp_c) AS hottest
FROM lake.ops.node_samples VERSION AS OF <good_snapshot_id>"

# 3. roll back
../lakehouse-sql.sh "
CALL lake.system.rollback_to_snapshot(
  table => 'ops.node_samples', snapshot_id => <good_snapshot_id>)"
```

Verify the spike is gone:

```sql
SELECT MAX(temp_c) FROM lake.ops.node_samples;   -- back to realistic Pi temperatures
```

Why this works, and what it costs:

A rollback does not delete anything. It writes a **new** snapshot whose state is a copy of the
old one, so the bad snapshot is still in `.snapshots` and still reachable by id. That is good —
it means the rollback is reversible and auditable — but it also means the bad data files are
still in the bucket, still costing space, until `expire_snapshots` runs past them. Compare with
scenario [32](../32-iceberg-maintenance/): compaction and expiry are what actually free space.

It also means the recovery window is exactly your snapshot retention. `maintain.py` keeps the
last 10 snapshots and expires anything older than 7 days — so this trick works for a week, and
then it does not. That retention number is a recovery-time decision disguised as a cleanup
setting, which is worth knowing before you need it.

</details>
