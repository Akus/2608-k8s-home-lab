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

## Migrate the cluster to Flux

Plan in FLUX-MIGRATION-PLAN.md (rewritten 2026-10-21): adopt the running add-ons by wrapping
each raw install in a `kustomization.yaml`, with no Helm reinstall, and bootstrap this repo.
Finish HTTPS first, because Flux applying the lab repo switches the Ingresses to
`*.lab.akos-demo.com`.

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
