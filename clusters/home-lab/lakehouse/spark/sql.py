"""Run ad-hoc SQL against the lakehouse and print the result.

The statement comes from /input/query.sql, which runbooks/lakehouse-sql.sh puts in a ConfigMap.
Multiple statements separated by `;` all run; the last one's result is shown in full.

  runbooks/lakehouse-sql.sh "SELECT * FROM lake.ops.node_samples ORDER BY recorded_at DESC LIMIT 5"
"""

import os
import sys

import lakehouse_common as lc

QUERY_FILE = os.environ.get("QUERY_FILE", "/input/query.sql")


def main() -> int:
    if not os.path.exists(QUERY_FILE):
        print(f"no {QUERY_FILE}; run this through runbooks/lakehouse-sql.sh", file=sys.stderr)
        return 1

    spark = lc.spark_session("lakehouse-sql")

    statements = [s.strip() for s in open(QUERY_FILE).read().split(";") if s.strip()]
    for i, stmt in enumerate(statements, 1):
        print(f"\n--- [{i}/{len(statements)}] {stmt.splitlines()[0][:100]} ---")
        df = spark.sql(stmt)
        if df.columns:
            df.show(100, truncate=False)
        else:
            print("(no result set)")

    spark.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
