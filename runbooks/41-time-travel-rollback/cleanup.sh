#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# If the rollback was done, there is nothing to clean. If it was not, remove the bad rows so
# the table is usable for the other scenarios.
"$ROOT/runbooks/lakehouse-sql.sh" \
  "DELETE FROM lake.ops.node_samples WHERE temp_c > 200" >/dev/null 2>&1 \
  && echo "Any remaining impossible rows deleted." \
  || echo "Nothing to clean up."
