# 32: The table has 400 files and 12 rows

> **Real cluster.** Operates on the live `lake.ops.node_samples` table. Compaction and snapshot
> expiry are destructive to *history*, not to data — read the task before running anything.

```bash
./setup.sh      # ~6 min: writes a batch of tiny commits, like a week of ingest
```

## Situation

`lakehouse-ingest-samples` runs every 15 minutes and appends two rows. It has been doing that
for a while. A developer complains that `SELECT COUNT(*)` on a table with a few hundred rows
now takes longer than it did on day one, and the Grafana panel built on it feels sluggish.

Nothing is broken. Everything is green.

## Task

1. Measure the problem before touching it: how many **data files**, **manifests** and
   **snapshots** does `lake.ops.node_samples` have, and how many rows?
2. Bring the file count down without losing a single row.
3. Make the old snapshots actually release their files.
4. Explain, in one sentence, why step 2 alone does not free any space.

Keep at least 10 snapshots of history — the developers use time travel.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- Iceberg exposes its own metadata as tables: `lake.ops.node_samples.files`,
  `.snapshots`, `.manifests`, `.history`. Query them with `../lakehouse-sql.sh`.
- `CALL lake.system.rewrite_data_files(...)`, `expire_snapshots(...)`,
  `remove_orphan_files(...)` — the `CALL` syntax needs the Iceberg SQL extensions, which the
  job template already enables.
- `rewrite_data_files` has a `target-file-size-bytes` option. Its default is 512MB. What does
  that mean for a table whose entire contents are a few kilobytes?
- After a rewrite, the old files are still referenced — by the older snapshots.
- `clusters/home-lab/lakehouse/spark/maintain.py` does all of this. Read it *after* you have
  tried the calls yourself.

</details>

<details><summary>Solution</summary>

Measure first:

```bash
../lakehouse-sql.sh "
SELECT (SELECT COUNT(*) FROM lake.ops.node_samples)           AS rows,
       (SELECT COUNT(*) FROM lake.ops.node_samples.files)     AS data_files,
       (SELECT COUNT(*) FROM lake.ops.node_samples.snapshots) AS snapshots"
```

Every append writes at least one new file and one new snapshot, so the counts track the number
of ingest runs, not the amount of data. That is the small-file problem: query planning opens
every file, and per-file overhead swamps a table this size.

```bash
# 1. combine the small files. The 32MB target matters: at the 512MB default,
#    Iceberg decides nothing is worth rewriting and does nothing at all.
../lakehouse-sql.sh "
CALL lake.system.rewrite_data_files(
  table => 'ops.node_samples',
  options => map('min-input-files','5','target-file-size-bytes','33554432'))"

# 2. the rewrite ADDED a snapshot; the old files are still referenced by older snapshots,
#    so nothing has been freed yet. Expire them.
../lakehouse-sql.sh "
CALL lake.system.expire_snapshots(
  table => 'ops.node_samples',
  older_than => TIMESTAMP '$(date -u -d '1 hour ago' +'%Y-%m-%d %H:%M:%S')',
  retain_last => 10)"

# 3. sweep files no snapshot references at all
../lakehouse-sql.sh "CALL lake.system.remove_orphan_files(table => 'ops.node_samples')"
```

The answer to question 4: **`rewrite_data_files` only writes new files and a new snapshot — it
never deletes.** The old files stay reachable through every snapshot that still lists them, so
space is reclaimed by `expire_snapshots`, not by the rewrite. Compaction makes queries fast;
expiry makes the bucket smaller. They are separate jobs because they have separate risks — one
is safe to run constantly, the other destroys your ability to time travel.

Order matters: expire before `remove_orphan_files`, or the sweep finds nothing to collect.

`remove_orphan_files` defaults to only considering files older than 3 days, deliberately — a
file that looks orphaned may belong to a write that is still in flight. Nothing writes
concurrently in this lab, but overriding that default in production is how people delete live
data.

This is what `lakehouse-maintain` runs nightly; see `maintain.py`.

</details>
