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

## Lakehouse — deployed, one step left

Deployed and verified on 2026-11-12: Argo CD, this project's own Jenkins (`ci`), Garage, the
Iceberg REST catalog, node-exporter, and the four Spark jobs. All pods Running with 0
restarts. `lake.ops.node_samples`, `weather`, `node_hourly` and `thermal_daily` all hold real
data, and the outdoor-vs-Pi-temperature join returns rows. Flux was dropped — it was planned
but never installed, so Argo CD took the GitOps slot outright.

**The one thing left: push this branch.** Argo CD and the Jenkins pipelines both pull
`https://github.com/Akus/2608-k8s-home-lab.git` at `main`, and none of these manifests are
there yet. Until they are:

- the three Argo Applications sit in `ComparisonError` ("app path does not exist") — harmless,
  and it is why they have not pruned the hand-applied resources;
- the four Jenkins pipelines exist but cannot check out their Jenkinsfile, so none has run.

Everything was applied with `kubectl apply -k` instead, which is why it is all live.

After pushing:

- Watch the three Applications go Synced/Healthy; they adopt the running resources.
- Trigger `lakehouse-ingest-samples` once by hand and confirm the agent pod spawns, kubectl is
  fetched to the `jenkins-tools` PVC, and the Spark Job is created.
- Then let the crons take over.

Remaining decisions:

- Whether the hil-lab Jenkins from 2609 is still worth running alongside this one; two
  controllers on 8 cores is the main CPU pressure on the cluster.
- Adopt the hand-installed add-ons (cert-manager, MetalLB, ingress-nginx, Litmus) into Argo as
  further Applications, now that the pattern is proven.
- Argo's and Jenkins' Ingresses are plain HTTP on `argocd.home.lan` / `ci.home.lan`; fold them
  into the HTTPS work above.
- `maintain.py` is the only job not yet exercised — it needs more snapshots to be interesting.
  Runbook 32 generates them.

## More chaos experiments

LitmusChaos operator + faults are installed (IMPLEMENTATION.md §8); only
`engines/pod-delete-rig-api.yaml` exists so far.

- Network latency between Jenkins and the rigs (`pod-network-latency` on the rig-sim pods).
- CPU/memory hog on rig-api; watch the effects in Grafana/Prometheus.
- Schedule recurring runs (a CronJob that re-applies an engine) once the experiments are stable.
- Install `chaos-exporter` so verdicts show up in Prometheus.

## Prometheus alerts

The lab's Prometheus (`hil-lab`) already loads app-level rules
(`kubernetes/base/monitoring/prometheus/config/alerts.yml` in the lab repo: rigs, Jenkins), but
nothing receives them, and there's nothing about the cluster or the Pis themselves.

- Enable Alertmanager: uncomment `../../base/extras` in the home-lab overlay (it also brings
  sqlite-web; split it out if that's not wanted), and give it a real receiver instead of the
  `alert-sink.invalid` webhook stub (e-mail, Telegram, ntfy, …).
- Node/cluster metrics: node-exporter (DaemonSet) + kube-state-metrics, plus kubelet/cAdvisor
  scraping via Kubernetes service discovery. The `cadvisor:8080` scrape job is a docker-compose
  leftover and has no target on the cluster.
- Rules for: node down / NotReady, CPU temperature > 70 °C (IMPLEMENTATION.md §10) and
  throttling, disk/SSD filling up, memory pressure, pods crash-looping or stuck Pending, PVCs
  near full, certificates expiring (cert-manager's `certmanager_certificate_expiration_timestamp_seconds`),
  failed chaos verdicts (with `chaos-exporter`, see "More chaos experiments").
- Expose Alertmanager's UI on `alertmanager.lab.akos-demo.com` like the other UIs.
