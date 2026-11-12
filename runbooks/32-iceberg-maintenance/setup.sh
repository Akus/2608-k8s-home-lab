#!/usr/bin/env bash
# Simulates a week of 15-minute ingest by making many small commits in one Spark session.
source "$(dirname "$0")/../lib.sh"
NS=lakehouse
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

SQL=""
for i in $(seq 1 24); do
  SQL+="INSERT INTO lake.ops.node_samples VALUES
    ('k8s-cp-1', 600, 2300000000, 55.$i, 8075000000, true, current_timestamp()),
    ('k8s-w-1',  900, 2100000000, 51.$i, 8075000000, true, current_timestamp());
"
done

echo "Writing 24 small commits (this is the slow part, ~5 min) ..."
"$ROOT/runbooks/lakehouse-sql.sh" "$SQL" >/dev/null 2>&1 || {
  echo "setup failed — is the lakehouse healthy? kubectl -n $NS get pods"; exit 1; }

echo "Done. lake.ops.node_samples now has a lot more files than it needs."
