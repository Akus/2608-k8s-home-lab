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

## Update FLUX-MIGRATION-PLAN.md to the current cluster state

The plan predates the HIL lab deploy. Things it doesn't cover yet:

- **More raw installs to migrate:** besides MetalLB + ingress-nginx, metrics-server
  (v0.7.2 + `--kubelet-insecure-tls` patch) and local-path-provisioner were also
  `kubectl apply`'d by hand.
- **The HIL lab itself:** a `GitRepository` for the lab repo plus a `Kustomization` with path
  `./kubernetes/overlays/home-lab`. Unlike the Helm-based add-ons, it needs no teardown:
  kustomize-controller applies server-side and adopts the objects `kubectl apply -k` created.
- **Secrets:** the overlay builds `lab-admin-credentials` from a gitignored `secrets.env`,
  which Flux's clone won't have. Switch to SOPS, or create the Secret by hand and drop the
  `secretGenerator`.
- **Order:** Flux bootstrap doesn't depend on migrating MetalLB/ingress first; the add-on
  migration and the lab Kustomization can be done independently.
- **Decide first whether Flux is still wanted:** `kubectl apply -k` is enough for a single-user
  lab; Flux is mainly for push-to-deploy and GitOps practice matching the AKS clusters.

## More chaos experiments

LitmusChaos operator + faults are installed (IMPLEMENTATION.md §8); only
`engines/pod-delete-rig-api.yaml` exists so far.

- Network latency between Jenkins and the rigs (`pod-network-latency` on the rig-sim pods).
- CPU/memory hog on rig-api; watch the effects in Grafana/Prometheus.
- Schedule recurring runs (a CronJob that re-applies an engine) once the experiments are stable.
- Install `chaos-exporter` so verdicts show up in Prometheus.
