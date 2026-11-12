"""Shared helpers for the lakehouse jobs.

Lives next to the job scripts in /opt/scripts, which Python puts on sys.path automatically,
so the jobs just `import lakehouse_common`.
"""

import json
import os
import ssl
import urllib.request

CATALOG = "lake"
NS = f"{CATALOG}.ops"

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://kubernetes.default.svc"


def k8s_get(path: str) -> dict:
    """GET against the in-cluster API server using the pod's ServiceAccount token."""
    with open(f"{SA}/token") as fh:
        token = fh.read().strip()
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    req = urllib.request.Request(f"{API}{path}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        return json.load(resp)


def http_get(url: str, timeout: int = 20) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read().decode()


def parse_cpu(value: str) -> int:
    """Kubernetes CPU quantity -> millicores. Handles 619m, 1, and nanocore forms."""
    value = value.strip()
    if value.endswith("n"):
        return int(int(value[:-1]) / 1_000_000)
    if value.endswith("u"):
        return int(int(value[:-1]) / 1_000)
    if value.endswith("m"):
        return int(value[:-1])
    return int(float(value) * 1000)


def parse_mem(value: str) -> int:
    """Kubernetes memory quantity -> bytes. Handles Ki/Mi/Gi and plain bytes."""
    value = value.strip()
    units = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4}
    for suffix, mult in units.items():
        if value.endswith(suffix):
            return int(value[: -len(suffix)]) * mult
    return int(value)


def node_temperature(node_ip: str) -> float | None:
    """SoC temperature in Celsius from node-exporter on the host network.

    Prefers the thermal_zone collector (what the Pi actually exposes) and falls back to hwmon,
    so this keeps working if the collector set changes. Returns None rather than raising: a
    node being unscrapeable should cost one column, not the whole run.
    """
    try:
        body = http_get(f"http://{node_ip}:9100/metrics")
    except Exception as exc:  # noqa: BLE001 - best effort by design
        print(f"  ! no node-exporter on {node_ip}: {exc}")
        return None

    readings = []
    for line in body.splitlines():
        if line.startswith("#"):
            continue
        if line.startswith("node_thermal_zone_temp") or line.startswith("node_hwmon_temp_celsius"):
            try:
                readings.append(float(line.rsplit(" ", 1)[1]))
            except (IndexError, ValueError):
                continue
    return max(readings) if readings else None


def spark_session(app_name: str):
    """Spark session. All Iceberg wiring is on the spark-submit command line (see
    spark-job.yaml) so it stays visible in the manifest rather than hidden in Python."""
    from pyspark.sql import SparkSession

    spark = SparkSession.builder.appName(app_name).getOrCreate()
    spark.sparkContext.setLogLevel("WARN")
    spark.sql(f"CREATE NAMESPACE IF NOT EXISTS {NS}")
    return spark


def location() -> tuple[str, float, float]:
    """Where the cluster physically is, for the weather join. Override via env."""
    return (
        os.environ.get("LAB_LOCATION", "budapest"),
        float(os.environ.get("LAB_LATITUDE", "47.4979")),
        float(os.environ.get("LAB_LONGITUDE", "19.0402")),
    )
