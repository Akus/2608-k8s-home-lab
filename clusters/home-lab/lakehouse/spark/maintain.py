"""Nightly table maintenance — the part people skip and then wonder why queries got slow.

The ingest writes two rows every 15 minutes, so node_samples gains ~96 tiny Parquet files a
day. Iceberg does not clean that up on its own. This job runs the three standard procedures
and prints file counts before and after, so the effect is visible rather than theoretical:

  rewrite_data_files   many small files -> few right-sized ones
  expire_snapshots     drop old snapshots (and let their files be deleted)
  remove_orphan_files  sweep files no snapshot references any more

Note the order: expire before remove_orphan, or the orphan sweep has nothing to collect.
"""

from datetime import datetime, timedelta, timezone

import lakehouse_common as lc

TABLES = ["node_samples", "weather", "node_hourly"]
RETAIN_DAYS = 7


def file_count(spark, table: str) -> int:
    return spark.sql(f"SELECT COUNT(*) AS n FROM {lc.NS}.{table}.files").first()["n"]


def snapshot_count(spark, table: str) -> int:
    return spark.sql(f"SELECT COUNT(*) AS n FROM {lc.NS}.{table}.snapshots").first()["n"]


def table_exists(spark, table: str) -> bool:
    return spark.catalog.tableExists(f"{lc.NS}.{table}")


def main() -> int:
    spark = lc.spark_session("lakehouse-maintain")
    cutoff = (datetime.now(timezone.utc) - timedelta(days=RETAIN_DAYS)).strftime("%Y-%m-%d %H:%M:%S")

    for table in TABLES:
        if not table_exists(spark, table):
            print(f"\n== {table}: does not exist yet, skipping ==")
            continue

        qualified = f"ops.{table}"
        files_before, snaps_before = file_count(spark, table), snapshot_count(spark, table)
        print(f"\n== {table}: {files_before} files, {snaps_before} snapshots ==")

        # target-file-size-bytes is 512MB by default, which on this lab would mean "never
        # rewrite anything". 32MB is a sane size for a dataset that grows by kilobytes a day.
        spark.sql(
            f"""
            CALL {lc.CATALOG}.system.rewrite_data_files(
                table => '{qualified}',
                options => map('min-input-files', '5', 'target-file-size-bytes', '33554432')
            )
            """
        ).show(truncate=False)

        spark.sql(
            f"""
            CALL {lc.CATALOG}.system.expire_snapshots(
                table => '{qualified}',
                older_than => TIMESTAMP '{cutoff}',
                retain_last => 10
            )
            """
        ).show(truncate=False)

        # Default older_than for this one is 3 days, deliberately conservative: a file that
        # looks orphaned might belong to a write that is still in flight. Nothing writes
        # concurrently in this lab, but keeping the default is the right habit.
        spark.sql(
            f"CALL {lc.CATALOG}.system.remove_orphan_files(table => '{qualified}')"
        ).show(truncate=False)

        print(f"   {table}: {files_before} -> {file_count(spark, table)} files, "
              f"{snaps_before} -> {snapshot_count(spark, table)} snapshots")

    spark.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
