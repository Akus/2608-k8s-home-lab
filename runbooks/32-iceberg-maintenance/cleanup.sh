#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
# Nothing to undo: the rows this scenario wrote are indistinguishable from real samples, and
# the maintenance you ran is what the nightly job does anyway. Just tidy leftover jobs.
kubectl -n lakehouse delete job -l job-name --ignore-not-found >/dev/null 2>&1 || true
kubectl -n lakehouse get job -o name 2>/dev/null | grep -E 'lakehouse-sql|rb32' | xargs -r kubectl -n lakehouse delete >/dev/null 2>&1 || true
echo "Leftover Spark jobs removed. Table left as-is (compacted, which is the desired state)."
