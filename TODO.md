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

## Chaos machine in the cluster

Run chaos experiments against the HIL lab (`hil-lab` namespace) to check it recovers from
failures: pod kills, node drains, network latency/partition, CPU/memory stress.

- Pick a tool: **Chaos Mesh** (CRD-based experiments + dashboard, covers pod/network/IO/stress
  faults) is the likely fit; **chaoskube** is enough if random pod kills are all that's wanted;
  LitmusChaos is heavier.
- Install it (raw manifest/Helm, like the other add-ons in IMPLEMENTATION.md §8), scoped to
  `hil-lab` only so it can't touch `kube-system`, MetalLB or ingress-nginx.
- Expose the dashboard via ingress-nginx (e.g. `chaos.home.lan`), behind auth.
- Start with a scheduled `PodChaos` on `rig-api`, then network delay between Jenkins and the
  rigs; watch the effects in Grafana/Prometheus.
