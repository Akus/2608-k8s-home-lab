# TODO

## Finish HTTPS for the web UIs (Let's Encrypt on lab.akos-demo.com)

cert-manager and the ClusterIssuers are installed, and the lab repo's overlay has the wildcard
Certificate and TLS Ingresses (not applied yet). Remaining, see HTTPS-CERTS.md Option B:

- B1: create the `cert-manager-home-lab` IAM user + access key, then the
  `cert-manager/route53-credentials` Secret.
- B5: Route53 A record `*.lab.akos-demo.com` → `192.168.1.240`.
- In the lab repo: `kubectl apply -k kubernetes/overlays/home-lab` (switches the Ingresses from
  `*.home.lan` to `*.lab.akos-demo.com`), wait for `lab-wildcard` to be Ready on staging, then
  switch `certificate.yaml` to `letsencrypt-prod`.

## Lakehouse — deployed and running

Deployed, pushed and verified on 2026-11-12. Argo CD, this project's own Jenkins (`ci`),
Garage, the Iceberg REST catalog, node-exporter and the four Spark pipelines. All three Argo
Applications Synced/Healthy; all pods Running with 0 restarts.

The full path is proven end to end: a cron-triggered Jenkins build spawns an agent pod, fetches
kubectl to the `jenkins-tools` PVC, stamps `spark-job.yaml`, and the Spark Job appends to
Iceberg — `lakehouse-ingest-samples` #3 ran unattended in 79s. `lake.ops.node_samples`,
`weather`, `node_hourly` and `thermal_daily` all hold real data, and the outdoor-vs-Pi
temperature join returns rows.

Measured idle footprint ~615Mi (LAKEHOUSE.md §7), far under the pre-deployment estimate.

Still open:

- `maintain.py` is the only job not yet exercised — it needs accumulated snapshots to do
  anything visible. Runbook `32` generates them.
- Add `ci.home.lan` and `argocd.home.lan` to the workstation hosts file / router DNS; both are
  plain HTTP and should fold into the HTTPS work above.
- Adopt the hand-installed add-ons (cert-manager, MetalLB, ingress-nginx, Litmus) into Argo as
  further Applications, now that the pattern is proven on three.
- Argo's `ignoreDifferences` on Garage's volumeClaimTemplates is a guess that has not been
  stress-tested; if the app flaps OutOfSync, that is the first place to look.

## hil-lab (2609) is scaled to zero

Done 2026-11-12. All eight `hil-lab` Deployments are at `replicas: 0`. Its Jenkins was pegged
at 991m against a 1-core limit, failing its 5s liveness probe and SIGKILL-restarting (278
restarts) — and this project has its own Jenkins in `ci` now, so it was pure legacy.

Cluster CPU went from 66%/38% to 18%/9% across the two nodes.

**Nothing was deleted.** All six PVCs are still Bound with their data (jenkins-home 4Gi,
prometheus-data 4Gi, maven-repo 2Gi, agent-workdir 2Gi, grafana-data 1Gi, rig-api-data
512Mi). All PVs are `Delete` reclaim policy, so deleting the namespace *would* destroy that
data permanently — scaling avoids the question entirely.

To bring it back:

```bash
kubectl -n hil-lab scale deploy --all --replicas=1
```

**What does not work while it is down** — worth knowing before you hit it rather than after:

- The LitmusChaos operator is scoped `WATCH_NAMESPACE=hil-lab`
  (`clusters/home-lab/litmus/operator/`), so there is nothing for it to target, and
  `litmus/hil-lab/engines/pod-delete-rig-api.yaml` has no pod to kill.
- Runbooks `04-rbac-ci-deployer`, `16-node-notready`, `20-drain-node`, `23-certificates` and
  `25-chaos-game-day` all reference `hil-lab` or `rig-api`.
- `grafana.home.lan`, `prometheus.home.lan`, `jenkins.home.lan` and `rig-api.home.lan` return
  nothing. The replacements for this environment are `ci.home.lan` (Jenkins) and
  `argocd.home.lan`.

If you decide to retire it for good rather than park it: re-scope the Litmus operator off
`hil-lab` first, then rewrite or retire those five runbooks, then delete the namespace. Back
up the PVCs if any of that data matters.

## More chaos experiments

LitmusChaos operator + faults are installed (IMPLEMENTATION.md §8); only
`engines/pod-delete-rig-api.yaml` exists so far.

- Network latency between Jenkins and the rigs (`pod-network-latency` on the rig-sim pods).
- CPU/memory hog on rig-api; watch the effects in Grafana/Prometheus.
- Schedule recurring runs (a CronJob that re-applies an engine) once the experiments are stable.
- Install `chaos-exporter` so verdicts show up in Prometheus.

## Prometheus alerts

This environment now has its own Prometheus and Grafana in `monitoring`
(`clusters/home-lab/monitoring/`), replacing the hil-lab pair that only ever scraped the rigs
and its own Jenkins. node-exporter and kube-state-metrics are in, and the scrape config uses
Kubernetes service discovery throughout — so the `cadvisor:8080` static target that was a
docker-compose leftover is gone rather than ported.

Covered by the `Home lab` dashboard on `dash.home.lan`: Pi SoC temperature against the 70 °C
throttle threshold, CPU and memory per node, root filesystem usage, container restarts by
namespace, and pods not Running.

Still to do:

- **No alerting at all yet.** There is no Alertmanager and no rule files — the dashboard will
  show you a hot Pi only if you happen to be looking. Rules worth writing first: node
  NotReady, SoC temperature > 70 °C sustained, disk above 80%, pods crash-looping, PVCs near
  full, certificates expiring (`certmanager_certificate_expiration_timestamp_seconds`), and
  Argo CD apps stuck OutOfSync.
- Pick a receiver that actually reaches you (ntfy, Telegram, e-mail) rather than the
  `alert-sink.invalid` webhook stub the hil-lab config used.
- Scrape the lakehouse itself: Garage's admin endpoint is already a scrape job, but nothing
  records Iceberg table/file counts, which is the leading indicator for the small-file problem
  in runbook 32.
- Our Jenkins has no Prometheus plugin, so there are no build metrics. Add it to
  `plugins.txt` if build duration/failure trends are worth having.
