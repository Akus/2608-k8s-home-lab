# 31: Rotate the object-store credentials with nothing going down

> **Real cluster.** You change the live `lakehouse` S3 key. Done in the right order nothing
> breaks; done in the wrong order you get scenario [30](../30-lakehouse-s3-auth/).

No `setup.sh` — the starting state is the working lakehouse.

## Situation

The `lakehouse-key` access key has been in a Secret, in your shell history and on a terminal
somewhere since the cluster was bootstrapped. Treat it as leaked. It needs replacing, and the
15-minute ingest should not miss a cycle.

## Task

Rotate to a brand-new Garage key with **no failed Spark job**, then prove the old key is dead.

Constraints, as if this were production:

- The old key must end up deleted from Garage, not just unused.
- `iceberg-rest` and any Spark Job must both be on the new key.
- Do not delete and recreate the bucket. The data stays.

Write down the order of operations *before* you start.

```bash
./verify.sh
```

<details><summary>Hints</summary>

- `kubectl -n lakehouse exec garage-0 -- /garage key --help`, and `bucket allow --help`.
- Garage lets a bucket have more than one key with RW at the same time. That is what makes a
  zero-downtime rotation possible at all.
- Which pods read the Secret, and *when* do they read it? A Secret used via `env` is read once,
  at container start. A Spark Job reads it when its pod starts, so the next job picks it up.
- The dangerous order is "delete old key, then update Secret". What is running in between?
- `kubectl -n lakehouse exec garage-0 -- /garage bucket info lakehouse` shows which keys have
  access right now.

</details>

<details><summary>Solution</summary>

New key first, old key last. The overlap is the whole trick:

```bash
G="kubectl -n lakehouse exec garage-0 -- /garage"

# 1. create the replacement and grant it access — now BOTH keys work
$G key create lakehouse-key-v2          # note the Key ID and Secret key
$G bucket allow --read --write lakehouse --key lakehouse-key-v2
$G bucket info lakehouse                # two keys with RW

# 2. point the Secret at the new key
kubectl -n lakehouse delete secret lakehouse-s3-credentials
kubectl -n lakehouse create secret generic lakehouse-s3-credentials \
  --from-literal=access-key-id='<new Key ID>' \
  --from-literal=secret-access-key='<new Secret key>'

# 3. restart the only long-lived consumer. Spark Jobs need nothing: the next one
#    to start mounts the new Secret by itself.
kubectl -n lakehouse rollout restart deploy/iceberg-rest
kubectl -n lakehouse rollout status deploy/iceberg-rest

# 4. prove the new key works BEFORE removing the old one
sed -e 's/__JOB__/rb31-check/' -e 's/__SCRIPT__/ingest_samples.py/' \
  ../../clusters/home-lab/lakehouse/spark/spark-job.yaml | kubectl apply -f -
kubectl -n lakehouse wait --for=condition=complete --timeout=300s job/rb31-check

# 5. only now, revoke and delete
$G bucket deny --read --write lakehouse --key lakehouse-key
$G key delete --yes lakehouse-key
```

Why this order: between steps 2 and 3 the running `iceberg-rest` still holds the *old*
credentials in its environment. If you had deleted the old key first, every request from that
pod would 403 until the restart finished — a real outage window, and exactly the symptom in
scenario 30.

The same shape applies to any credential with a long-lived consumer: **overlap, switch,
verify, then revoke.** Four steps, never three.

</details>
