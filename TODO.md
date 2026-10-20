# TODO

## Self-signed HTTPS for the web UIs

The HIL lab (`2609-Java-Jenkins-CICD-for-Siemens-test-rigs`, namespace `hil-lab`) is served
over plain HTTP via ingress-nginx: `jenkins`, `grafana`, `prometheus`, `rig-api` `.home.lan`.

- Install cert-manager (raw manifest, like the other add-ons in IMPLEMENTATION.md §8).
- Create a self-signed root CA: a `selfSigned` ClusterIssuer issues a CA `Certificate`, and a
  `ca` ClusterIssuer signs everything else with it (one CA to trust instead of one cert per site).
- In the lab repo's `kubernetes/overlays/home-lab/ingress.yaml`: add
  `cert-manager.io/cluster-issuer` and a `tls:` block per Ingress; switch `JENKINS_PUBLIC_URL`
  and `GF_SERVER_ROOT_URL` in the overlay to `https://`.
- Import the CA cert into Windows' "Trusted Root Certification Authorities" (and WSL's
  `/usr/local/share/ca-certificates` + `update-ca-certificates`) so browsers don't warn.

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
