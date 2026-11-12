# 23: Check and renew certificates (real cluster)

> **Real cluster.** Renewing the control plane's certificates restarts the API server,
> controller-manager and scheduler. Expect about a minute without `kubectl`. Running workloads
> aren't affected.

A kubeadm cluster has two kinds of certificates that expire:
- **Control plane** (API server, etcd, kubeconfigs): issued by kubeadm for **1 year**. If
  they lapse, `kubectl` and the nodes are locked out. It's the classic "cluster died on its
  birthday" outage.
- **Ingress** (`*.lab.akos-demo.com`): issued by Let's Encrypt for 90 days, renewed by
  cert-manager.

```bash
./setup.sh     # records today's certificate dates, so verify.sh can tell they were renewed
```

## Task

**Control plane:**
1. When does each control-plane certificate expire? And the CAs?
2. Renew them all now, and make the running components actually **use** the new ones.
3. Your laptop's kubeconfig embeds a client certificate too. Is it renewed? Fix it.
4. The kubelets have client certificates as well. Do they need the same treatment?

**Ingress** (only once HTTPS is set up, see TODO.md):
5. When does the wildcard certificate that ingress-nginx serves expire, and when will
   cert-manager renew it? Read the cert as a browser sees it, not just the Secret.
6. Force an early renewal (on the **staging** issuer, because prod has rate limits) and confirm
   ingress-nginx serves the new certificate.

```bash
./verify.sh
```

<details><summary>Hints</summary>

- `sudo kubeadm certs check-expiration` on `k8s-cp-1`.
- `kubeadm certs renew` writes new files, but the running static pods keep the old ones in
  memory until restarted. The kubelet restarts a static pod when its manifest leaves and
  comes back to `/etc/kubernetes/manifests/`.
- `echo | openssl s_client -connect 192.168.1.11:6443 2>/dev/null | openssl x509 -noout -dates`
  shows what the API server is actually serving.
- Kubelet: look for `rotateCertificates` in `/var/lib/kubelet/config.yaml`, and at
  `/var/lib/kubelet/pki/`.
- cert-manager: `kubectl -n hil-lab get certificate lab-wildcard -o yaml` (`status.notAfter`,
  `status.renewalTime`). `cmctl renew` forces a renewal; deleting the Secret also works,
  but leaves the ingress without a cert until the new one is issued.

</details>

<details><summary>Solution</summary>

**Control plane**, on `k8s-cp-1`:

```bash
sudo kubeadm certs check-expiration        # certs: 1 year from kubeadm init; CAs: 10 years
sudo kubeadm certs renew all
cd /etc/kubernetes
sudo mkdir -p /tmp/manifests && sudo mv manifests/*.yaml /tmp/manifests/
sleep 30                                   # kubelet stops the static pods
sudo crictl ps | grep -E 'kube-apiserver|etcd|controller|scheduler'   # repeat until empty
sudo mv /tmp/manifests/*.yaml manifests/
sudo kubeadm certs check-expiration        # 365d again
sudo cat /etc/kubernetes/admin.conf        # renewed too
```

**Laptop kubeconfig**: it's a copy of `admin.conf` from the day you set up the cluster, so
it still has the old client certificate. It keeps working until that expires. Renewing
doesn't revoke the old one; Kubernetes has no certificate revocation. Refresh it:

```bash
ssh k8s-cp-1 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/config.new
KUBECONFIG=~/.kube/config.new kubectl get nodes && mv ~/.kube/config.new ~/.kube/config
```

(If your `~/.kube/config` holds other clusters too, merge only the `users` entry instead.)

**Kubelets**: no action needed. kubeadm sets `rotateCertificates: true`, so the kubelet
requests a new client cert from the API server well before expiry
(`/var/lib/kubelet/pki/kubelet-client-current.pem` is a symlink to the latest).
Its **serving** certificate is self-signed and not rotated, which is why metrics-server
needs `--kubelet-insecure-tls` (IMPLEMENTATION.md §8).

`kubeadm upgrade apply` renews everything as a side effect (scenario 22): upgrading once a year
is the other way to never hit this.

**Ingress:**

```bash
echo | openssl s_client -connect 192.168.1.240:443 -servername jenkins.lab.akos-demo.com 2>/dev/null \
  | openssl x509 -noout -issuer -dates
kubectl -n hil-lab get certificate lab-wildcard \
  -o jsonpath='{.status.notAfter}{"  renew at: "}{.status.renewalTime}{"\n"}'

# cmctl: https://cert-manager.io/docs/reference/cmctl/
cmctl renew -n hil-lab lab-wildcard
kubectl -n hil-lab get certificaterequest -w      # a new one, Approved, then Ready
```

By default, cert-manager renews at 2/3 of the lifetime: 30 days before a 90-day cert expires.

</details>
