"""Bronze: append the current outdoor weather where the cluster lives.

Open-Meteo, no API key, no account. Hourly from Jenkins — the API's `current` block updates on
a 15-minute interval, so hourly is plenty and keeps the table honest about its resolution.

Exists so the telemetry has something to join against: the question this lakehouse is built to
answer is whether a warm room actually throttles the Pis.

Target: lake.ops.weather
"""

import json
from datetime import datetime, timezone

from pyspark.sql import functions as F

import lakehouse_common as lc

TABLE = f"{lc.NS}.weather"
ENDPOINT = (
    "https://api.open-meteo.com/v1/forecast"
    "?latitude={lat}&longitude={lon}"
    "&current=temperature_2m,relative_humidity_2m,wind_speed_10m"
    "&timezone=UTC"
)


def main() -> int:
    spark = lc.spark_session("lakehouse-ingest-weather")
    name, lat, lon = lc.location()

    spark.sql(
        f"""
        CREATE TABLE IF NOT EXISTS {TABLE} (
            location     STRING,
            temp_c       DOUBLE,
            humidity_pct DOUBLE,
            wind_kmh     DOUBLE,
            observed_at  TIMESTAMP
        ) USING iceberg
        PARTITIONED BY (days(observed_at))
        TBLPROPERTIES ('write.parquet.compression-codec' = 'zstd')
        """
    )

    payload = json.loads(lc.http_get(ENDPOINT.format(lat=lat, lon=lon)))
    current = payload["current"]
    row = {
        "location": name,
        "temp_c": float(current["temperature_2m"]),
        "humidity_pct": float(current["relative_humidity_2m"]),
        "wind_kmh": float(current["wind_speed_10m"]),
        # Open-Meteo returns naive local-is-UTC time because we asked for timezone=UTC.
        "observed_at": current["time"] + ":00",
    }
    print(f"  {name}: {row['temp_c']}C, {row['humidity_pct']}% humidity, "
          f"{row['wind_kmh']} km/h at {row['observed_at']}Z")

    # The API returns the same `current` block for a whole 15-minute interval, so a retried or
    # overlapping run would double-count. Skip it rather than writing a duplicate — bronze
    # should be append-only, not append-carelessly.
    already = spark.sql(
        f"SELECT COUNT(*) AS n FROM {TABLE} "
        f"WHERE location = '{name}' AND observed_at = TIMESTAMP '{row['observed_at']}'"
    ).first()["n"]
    if already:
        print(f"observation at {row['observed_at']} already landed; nothing to do")
        spark.stop()
        return 0

    df = spark.createDataFrame([row]).select(
        F.col("location").cast("string"),
        F.col("temp_c").cast("double"),
        F.col("humidity_pct").cast("double"),
        F.col("wind_kmh").cast("double"),
        F.to_timestamp("observed_at").alias("observed_at"),
    )
    df.writeTo(TABLE).append()
    print(f"appended 1 row to {TABLE}")

    spark.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
