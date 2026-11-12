#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "Writing the bad batch (~90s) ..."
"$ROOT/runbooks/lakehouse-sql.sh" "
INSERT INTO lake.ops.node_samples VALUES
  ('k8s-cp-1', 999999, 999999999999, 4821.7, 8075000000, true, current_timestamp(), NULL),
  ('k8s-cp-1', 999999, 999999999999, 5123.4, 8075000000, true, current_timestamp(), NULL),
  ('k8s-w-1',  999999, 999999999999, 4977.2, 8075000000, true, current_timestamp(), NULL),
  ('k8s-w-1',  999999, 999999999999, 5310.8, 8075000000, true, current_timestamp(), NULL)
" >/dev/null 2>&1 || {
  # the table may not have the swap_bytes column from scenario 40
  "$ROOT/runbooks/lakehouse-sql.sh" "
INSERT INTO lake.ops.node_samples VALUES
  ('k8s-cp-1', 999999, 999999999999, 4821.7, 8075000000, true, current_timestamp()),
  ('k8s-cp-1', 999999, 999999999999, 5123.4, 8075000000, true, current_timestamp()),
  ('k8s-w-1',  999999, 999999999999, 4977.2, 8075000000, true, current_timestamp()),
  ('k8s-w-1',  999999, 999999999999, 5310.8, 8075000000, true, current_timestamp())
" >/dev/null 2>&1 || { echo "setup failed — is the lakehouse healthy?"; exit 1; }
}
echo "Done. lake.ops.node_samples now contains rows that claim the Pis are at ~5000 C."
