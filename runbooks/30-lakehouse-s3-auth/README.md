# 30: Spark jobs fail, nobody changed Spark

> **Real cluster.** This breaks the `lakehouse` namespace's S3 credentials. Nothing outside it
> is touched, and `cleanup.sh` puts the original key back.

```bash
./setup.sh
```

## Situation

The nightly `lakehouse-maintain` build went red and the 15-minute ingest has been failing ever
since. The Spark pods start, run for about a minute, then exit 1. Nobody deployed Spark, the
catalog, or Garage today.

A developer's first report: *"Iceberg is broken."*

## Task

Find out which of the three layers is actually failing — Spark, the Iceberg REST catalog, or
Garage — and fix it so a job succeeds again.

```bash
# reproduce the failure
sed -e 's/__JOB__/rb30-check/' -e 's/__SCRIPT__/ingest_samples.py/' \
  ../../clusters/home-lab/lakehouse/spark/spark-job.yaml | kubectl apply -f -
kubectl -n lakehouse logs -f job/rb30-check
```

Do not just recreate the Secret from `cleanup.sh`. The point is to read the error from the
layer that produced it.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- Read the Spark traceback from the bottom. Which component is named in the final
  `Caused by` / `Server error:` line? `ServiceFailureException: Server error:` means the REST
  catalog answered with a 500 — the failure happened *inside the catalog*, not in Spark.
- `kubectl -n lakehouse logs deploy/iceberg-rest --tail=50`. What status code is Garage
  returning to it?
- `kubectl -n lakehouse logs garage-0 --tail=50` — Garage logs every rejected request.
- Which Secret do both `iceberg-rest` and the Spark Job mount? `kubectl -n lakehouse get
  secret lakehouse-s3-credentials -o jsonpath='{.data.access-key-id}' | base64 -d`
- `kubectl -n lakehouse exec garage-0 -- /garage key list` — does that key id exist?
- Changing a Secret does **not** restart the pods that mounted it as env vars.

</details>

<details><summary>Solution</summary>

The layers answer in this order:

| Layer | What it says | Means |
|---|---|---|
| Spark | `ServiceFailureException: Server error: ...` | the catalog 500'd; Spark is fine |
| `iceberg-rest` | `S3Exception ... Status Code: 403` | Garage refused *it* |
| `garage-0` | `Forbidden: Invalid access key` | the key id is not one of Garage's |

`setup.sh` replaced `access-key-id` in `lakehouse-s3-credentials` with a key Garage has never
issued. Both `iceberg-rest` and every Spark Job read that Secret, so everything that touches
object storage fails while the catalog's own SQLite metadata keeps working — which is exactly
why `SHOW NAMESPACES` still succeeds and writing a table does not.

```bash
# the real key id, from Garage itself
kubectl -n lakehouse exec garage-0 -- /garage key list

kubectl -n lakehouse delete secret lakehouse-s3-credentials
kubectl -n lakehouse create secret generic lakehouse-s3-credentials \
  --from-literal=access-key-id='<Key ID>' \
  --from-literal=secret-access-key='<Secret key>'

# env-var Secrets are read at container start — the running pod keeps the old value
kubectl -n lakehouse rollout restart deploy/iceberg-rest
```

Secret keys are only shown when the key is created. If you lost it, you do not recover it —
you issue a new one, which is scenario [31](../31-s3-key-rotation/).

The lesson worth keeping: a three-tier failure reports itself at the top, and every layer
above the broken one reports it as "the thing below me returned an error". Always walk down.

</details>
