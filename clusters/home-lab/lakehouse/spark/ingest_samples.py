"""Bronze: append one sample of every node's CPU, memory and SoC temperature.

Runs every 15 minutes from Jenkins. Each run writes two rows (one per Pi), which is a
deliberately pathological write pattern for a table format — it is how you end up with
thousands of tiny Parquet files, and why maintain.py exists.

Source: metrics.k8s.io for CPU/memory, node-exporter on the host network for temperature.
Target: lake.ops.node_samples
"""

from datetime import datetime, timezone

from pyspark.sql import functions as F

import lakehouse_common as lc

TABLE = f"{lc.NS}.node_samples"


def collect() -> list[dict]:
    nodes = lc.k8s_get("/api/v1/nodes")["items"]
    usage = {u["metadata"]["name"]: u["usage"] for u in lc.k8s_get("/apis/metrics.k8s.io/v1beta1/nodes")["items"]}
    now = datetime.now(timezone.utc).replace(microsecond=0)

    rows = []
    for node in nodes:
        name = node["metadata"]["name"]
        ip = next(
            (a["address"] for a in node["status"]["addresses"] if a["type"] == "InternalIP"),
            None,
        )
        used = usage.get(name, {})
        rows.append(
            {
                "node": name,
                "cpu_millicores": lc.parse_cpu(used.get("cpu", "0")),
                "mem_bytes": lc.parse_mem(used.get("memory", "0")),
                "temp_c": lc.node_temperature(ip) if ip else None,
                "allocatable_mem_bytes": lc.parse_mem(node["status"]["allocatable"]["memory"]),
                "ready": any(
                    c["type"] == "Ready" and c["status"] == "True"
                    for c in node["status"]["conditions"]
                ),
                "recorded_at": now.isoformat(),
            }
        )
    return rows


def main() -> int:
    spark = lc.spark_session("lakehouse-ingest-samples")

    spark.sql(
        f"""
        CREATE TABLE IF NOT EXISTS {TABLE} (
            node                  STRING,
            cpu_millicores        INT,
            mem_bytes             BIGINT,
            temp_c                DOUBLE  COMMENT 'SoC temperature, null if node-exporter was unreachable',
            allocatable_mem_bytes BIGINT,
            ready                 BOOLEAN,
            recorded_at           TIMESTAMP
        ) USING iceberg
        PARTITIONED BY (days(recorded_at))
        TBLPROPERTIES ('write.parquet.compression-codec' = 'zstd')
        """
    )

    rows = collect()
    for row in rows:
        temp = f"{row['temp_c']:.1f}C" if row["temp_c"] is not None else "temp n/a"
        print(f"  {row['node']}: {row['cpu_millicores']}m cpu, "
              f"{row['mem_bytes'] / 1024**2:.0f}Mi mem, {temp}")

    df = spark.createDataFrame(rows).select(
        F.col("node").cast("string"),
        F.col("cpu_millicores").cast("int"),
        F.col("mem_bytes").cast("bigint"),
        F.col("temp_c").cast("double"),
        F.col("allocatable_mem_bytes").cast("bigint"),
        F.col("ready").cast("boolean"),
        F.to_timestamp("recorded_at").alias("recorded_at"),
    )
    df.writeTo(TABLE).append()
    print(f"appended {df.count()} row(s) to {TABLE}")

    total, files = spark.sql(
        f"SELECT (SELECT COUNT(*) FROM {TABLE}) AS rows, "
        f"(SELECT COUNT(*) FROM {TABLE}.files) AS files"
    ).first()
    print(f"{TABLE}: {total} rows across {files} data files")

    spark.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
