# HTTPS certificates for the web UIs

The HIL lab (`2609-Java-Jenkins-CICD-for-Siemens-test-rigs`, namespace `hil-lab`) is served over
plain HTTP via ingress-nginx: `jenkins`, `grafana`, `prometheus`, `rig-api` `.home.lan`. Two ways
to add TLS, both using cert-manager:

- **A. Self-signed CA** — works with `*.home.lan` as is, nothing exposed or bought, but every
  client has to import the CA.
- **B. Let's Encrypt via Route53 (`akos-demo.com`)** — publicly trusted certs on every device
  with no CA import; needs an IAM key for DNS-01 and new hostnames under `lab.akos-demo.com`.

**Option B is what's implemented** (2026-10-21): cert-manager + ClusterIssuers in
[`clusters/home-lab/cert-manager/`](clusters/home-lab/cert-manager/), the wildcard Certificate
and TLS Ingresses in the lab repo's `kubernetes/overlays/home-lab/`. Option A is kept for
reference. Both start with step 0.

## 0. Install cert-manager — [CP]

Raw manifest, like the other add-ons in IMPLEMENTATION.md §8 (arm64 images included). The
patch is for Option B, see B6:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml
kubectl -n cert-manager patch deployment cert-manager --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--dns01-recursive-nameservers-only"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53"}]'
kubectl -n cert-manager rollout status deploy/cert-manager-webhook
```

---

## Option A: self-signed CA

### A1. CA chain

A `selfSigned` issuer creates a root CA, and a `ca` issuer signs every site's cert with it — one
CA to trust instead of one cert per site.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: selfsigned }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: home-lab-ca, namespace: cert-manager }
spec:
  isCA: true
  commonName: home-lab-ca
  secretName: home-lab-ca
  duration: 87600h        # 10 years, so the root rarely needs re-importing
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: selfsigned, kind: ClusterIssuer }
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: home-lab-ca }
spec:
  ca: { secretName: home-lab-ca }
```

### A2. TLS on the Ingresses

In the lab repo's `kubernetes/overlays/home-lab/ingress.yaml`, per Ingress:

```yaml
metadata:
  name: jenkins
  annotations:
    cert-manager.io/cluster-issuer: home-lab-ca
spec:
  tls:
    - hosts: [jenkins.home.lan]
      secretName: jenkins-tls
```

cert-manager creates and renews each `*-tls` Secret; ingress-nginx redirects HTTP→HTTPS once TLS
is configured. Switch `JENKINS_PUBLIC_URL` and `GF_SERVER_ROOT_URL` in the overlay to `https://`
and update the "no cert-manager on this cluster" comment at the top of `ingress.yaml`.

### A3. Trust the CA on clients

```bash
kubectl -n cert-manager get secret home-lab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > home-lab-ca.crt
# WSL:
sudo cp home-lab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
# Windows (admin PowerShell):
#   Import-Certificate -FilePath home-lab-ca.crt -CertStoreLocation Cert:\LocalMachine\Root
```

Firefox uses its own store (import there, or set `security.enterprise_roots.enabled`). Phones
need the CA installed separately.

### A4. Verify

```bash
kubectl -n hil-lab get certificate     # all READY=True
curl -v https://jenkins.home.lan       # no certificate error
```

---

## Option B: Let's Encrypt via Route53

Let's Encrypt can't issue for `.home.lan` — only for public domains you control. Use the DNS-01
challenge: cert-manager writes a TXT record through the Route53 API, so the cluster stays
LAN-only (HTTP-01 would need port 80 open to the internet). Hostnames move to
`*.lab.akos-demo.com`: `jenkins.lab.akos-demo.com`, `grafana.lab.akos-demo.com`, etc.

### B1. IAM user scoped to the challenge record

Create an IAM user (e.g. `cert-manager-home-lab`) with the inline policy in
[`clusters/home-lab/cert-manager/route53-iam-policy.json`](clusters/home-lab/cert-manager/route53-iam-policy.json).
It can only change TXT records named `_acme-challenge.lab.akos-demo.com`, so a leaked key can't
touch anything else in the zone; `ListHostedZonesByName` lets cert-manager find the zone itself,
so no zone ID needs to go into the manifests.

```bash
aws iam create-user --user-name cert-manager-home-lab
aws iam put-user-policy --user-name cert-manager-home-lab --policy-name route53-acme-dns01 \
  --policy-document file://clusters/home-lab/cert-manager/route53-iam-policy.json
aws iam create-access-key --user-name cert-manager-home-lab
```

Store the access key in the cluster (don't commit it):

```bash
kubectl -n cert-manager create secret generic route53-credentials \
  --from-literal=access-key-id=AKIA... --from-literal=secret-access-key=...
```

### B2. ClusterIssuers (staging + prod)

[`clusters/home-lab/cert-manager/clusterissuers.yaml`](clusters/home-lab/cert-manager/clusterissuers.yaml):
`letsencrypt-staging` and `letsencrypt-prod`, identical apart from the ACME server and account
key Secret. Test against staging first so failures don't hit prod rate limits.

```bash
kubectl apply -f clusters/home-lab/cert-manager/clusterissuers.yaml
kubectl get clusterissuer        # READY=True once route53-credentials exists
```

### B3. One wildcard cert

One cert covers every UI, and only `*.lab.akos-demo.com` shows up in public Certificate
Transparency logs (not each hostname). Lives in the lab repo as
`kubernetes/overlays/home-lab/certificate.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: lab-wildcard, namespace: hil-lab }
spec:
  secretName: lab-wildcard-tls
  dnsNames: ["*.lab.akos-demo.com"]
  issuerRef: { name: letsencrypt-staging, kind: ClusterIssuer }
```

Watch it with `kubectl -n hil-lab describe certificate lab-wildcard` and
`kubectl get challenges -A`. Once Ready on staging, switch `issuerRef` to `letsencrypt-prod`,
re-apply, and `kubectl -n hil-lab delete secret lab-wildcard-tls` so the prod cert is issued
right away instead of at the staging cert's renewal.

### B4. Ingresses

In the lab repo's `kubernetes/overlays/home-lab/ingress.yaml` — no annotation needed, they all
share the wildcard Secret:

```yaml
spec:
  ingressClassName: nginx
  tls:
    - hosts: [jenkins.lab.akos-demo.com]
      secretName: lab-wildcard-tls
  rules:
    - host: jenkins.lab.akos-demo.com
```

Same for grafana, prometheus, rig-api. Set `JENKINS_PUBLIC_URL` and `GF_SERVER_ROOT_URL` to the
new `https://` URLs.

### B5. Name resolution on the LAN

Simplest: a public wildcard A record in Route53, `*.lab.akos-demo.com` → ingress-nginx's MetalLB
IP (`kubectl -n ingress-nginx get svc ingress-nginx-controller`). Every LAN device resolves it, no
hosts files.

- It exposes a private IP in public DNS — harmless, it's unreachable from outside.
- Some routers drop DNS answers pointing at private IPs (DNS rebind protection). If the names
  don't resolve at home, whitelist `akos-demo.com` there, or use split DNS on the router/Pi-hole.

### B6. Gotcha: split DNS breaks the challenge self-check

Before asking Let's Encrypt to validate, cert-manager looks up the `_acme-challenge` TXT record
itself. If the router/Pi-hole answers `lab.akos-demo.com` locally, that lookup fails and the cert
never issues. The patch in step 0 avoids that by making cert-manager ask public resolvers:

```
--dns01-recursive-nameservers-only
--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53
```

Not strictly needed with the public A record from B5, but harmless and already applied.

### Result

Trusted by every browser and phone with nothing to import; cert-manager renews every ~60 days.
