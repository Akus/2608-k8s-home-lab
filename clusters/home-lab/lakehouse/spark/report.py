"""Silver + gold: roll the raw samples up, then answer the question the lab was built for.

Silver (lake.ops.node_hourly) is built with MERGE INTO rather than INSERT, so re-running the
job for a day that already landed updates those hours instead of duplicating them. That makes
the pipeline idempotent, which matters the first time a Jenkins build gets retried.

Gold is the join: outdoor temperature against Pi temperature and CPU, which is the one thing
neither table can answer on its own.
"""

from pyspark.sql import functions as F

import lakehouse_common as lc

SAMPLES = f"{lc.NS}.node_samples"
WEATHER = f"{lc.NS}.weather"
HOURLY = f"{lc.NS}.node_hourly"
THERMAL = f"{lc.NS}.thermal_daily"


def main() -> int:
    spark = lc.spark_session("lakehouse-report")

    spark.sql(
        f"""
        CREATE TABLE IF NOT EXISTS {HOURLY} (
            node      STRING,
            hour      TIMESTAMP,
            samples   INT,
            avg_cpu_m DOUBLE,
            avg_mem_mb DOUBLE,
            avg_temp_c DOUBLE,
            max_temp_c DOUBLE
        ) USING iceberg
        PARTITIONED BY (days(hour))
        """
    )

    # UPDATE SET * / INSERT * need the Iceberg SQL extensions, which spark-job.yaml enables.
    spark.sql(
        f"""
        MERGE INTO {HOURLY} t
        USING (
            SELECT node,
                   date_trunc('HOUR', recorded_at)      AS hour,
                   CAST(COUNT(*) AS INT)                AS samples,
                   ROUND(AVG(cpu_millicores), 1)        AS avg_cpu_m,
                   ROUND(AVG(mem_bytes) / 1048576, 1)   AS avg_mem_mb,
                   ROUND(AVG(temp_c), 1)                AS avg_temp_c,
                   ROUND(MAX(temp_c), 1)                AS max_temp_c
            FROM {SAMPLES}
            GROUP BY node, date_trunc('HOUR', recorded_at)
        ) s
        ON t.node = s.node AND t.hour = s.hour
        WHEN MATCHED THEN UPDATE SET *
        WHEN NOT MATCHED THEN INSERT *
        """
    )
    print(f"{HOURLY}: {spark.table(HOURLY).count()} node-hours")

    print("\n== last 12 node-hours ==")
    spark.sql(
        f"SELECT node, hour, samples, avg_cpu_m, avg_mem_mb, avg_temp_c, max_temp_c "
        f"FROM {HOURLY} ORDER BY hour DESC, node LIMIT 12"
    ).show(truncate=False)

    # --- the payoff: does a warm room throttle the Pis? ----------------------------------
    # Two tables landed by two independent pipelines, joined on the hour. This is the thing a
    # lakehouse is for; neither table can answer it alone.
    weather_hours = spark.table(WEATHER).select(
        F.date_trunc("HOUR", "observed_at").alias("hour"),
        F.col("temp_c").alias("outdoor_c"),
        F.col("humidity_pct"),
    )
    joined = (
        spark.table(HOURLY)
        .join(weather_hours, on="hour", how="inner")
        .groupBy(F.round("outdoor_c", 0).alias("outdoor_c"))
        .agg(
            F.round(F.avg("avg_temp_c"), 1).alias("pi_temp_c"),
            F.round(F.avg("avg_cpu_m"), 0).alias("pi_cpu_m"),
            F.count("*").alias("node_hours"),
        )
        .orderBy("outdoor_c")
    )
    print("== outdoor temperature vs. Pi temperature ==")
    if joined.isEmpty():
        print("  (no overlapping hours yet — needs one weather row and one sample row in the")
        print("   same hour; give the two ingest pipelines a cycle to line up)")
    else:
        joined.show(truncate=False)

    spark.sql(
        f"""
        CREATE TABLE IF NOT EXISTS {THERMAL} (
            day          DATE,
            node         STRING,
            peak_temp_c  DOUBLE,
            hot_hours    INT COMMENT 'hours where max_temp_c > 70, the throttling threshold',
            avg_cpu_m    DOUBLE
        ) USING iceberg
        """
    )
    spark.sql(
        f"""
        MERGE INTO {THERMAL} t
        USING (
            SELECT CAST(hour AS DATE)                                  AS day,
                   node,
                   MAX(max_temp_c)                                     AS peak_temp_c,
                   CAST(SUM(CASE WHEN max_temp_c > 70 THEN 1 ELSE 0 END) AS INT) AS hot_hours,
                   ROUND(AVG(avg_cpu_m), 1)                            AS avg_cpu_m
            FROM {HOURLY} GROUP BY CAST(hour AS DATE), node
        ) s
        ON t.day = s.day AND t.node = s.node
        WHEN MATCHED THEN UPDATE SET *
        WHEN NOT MATCHED THEN INSERT *
        """
    )
    print(f"== {THERMAL} (70C is the Pi throttling threshold, see TODO.md) ==")
    spark.sql(f"SELECT * FROM {THERMAL} ORDER BY day DESC, node LIMIT 10").show(truncate=False)

    spark.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
