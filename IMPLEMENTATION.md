# Implementation Guide — Raspberry Pi 4B Kubernetes cluster

Detailed, command-by-command install walkthrough. Short overview:
[README.md](README.md).

Notation: **[CP]** = control-plane node only, **[W]** = worker node only,
**[ALL]** = run on both nodes.

---

## 0. Network plan (decide up front)

| Network | Suggested range | Notes |
|---|---|---|
| LAN (nodes) | `192.168.0.0/24` (gateway `192.168.0.1`) | your router's subnet |
| Node static IPs | `192.168.0.11` (CP), `192.168.0.12` (W) | DHCP reservation or netplan |
| Pod CIDR | `10.244.0.0/16` | **must not** overlap the LAN |
| MetalLB pool | `192.168.0.240–192.168.0.250` | free range inside the LAN |

> ⚠️ **Important:** Calico's default `192.168.0.0/16` pod CIDR overlaps the typical home
> `192.168.x.0/24` LAN, which causes hard-to-debug routing issues. That's why we use
> `10.244.0.0/16` for the pod network.

---

## 1. Hardware prep

- [ ] Mount cooling (fan + heatsink) on both nodes.
- [ ] Have a micro-HDMI → HDMI adapter ready for initial setup (then headless/SSH).

> Static IPs are assigned **after** first boot, not now — you need each Pi's MAC address
> first, and the easiest way to get it is from the booted node. See [2.4](#24-assign-a-static-ip-discover-mac-then-pin).
> The IP just has to be fixed before `kubeadm init` (section 6), since the API server
> address must be stable.

---

## 2. Boot from SSD

**Big picture:** the Pi 4B can boot straight off a USB SSD, so you do **not** need an SD
card for the OS. You flash Ubuntu directly onto each SSD from your PC. An SD card is used
**only once per Pi** to update the bootloader firmware (EEPROM) so it will actually try USB
first. If your Pis already have recent firmware with USB boot enabled you can skip 2.1, but
doing it guarantees a known-good boot order.

You'll need on your PC: **[Raspberry Pi Imager](https://www.raspberrypi.com/software/)**, a
microSD card (any small one, reused for both Pis), and a USB-to-SSD connection (the SSD in
its USB 3.0 enclosure/adapter).

### 2.1 Update the Pi bootloader for USB boot (via SD card) — [ALL]

This reprograms the Pi's EEPROM so USB is first in the boot order. It's the classic
chicken-and-egg fix: the SSD can't boot until the firmware knows to look at USB.

1. Insert the microSD card into your PC.
2. Open **Raspberry Pi Imager**.
3. **Choose Device** → *Raspberry Pi 4*.
4. **Choose OS** → *Misc utility images* → *Bootloader (Pi 4 family)* → *USB Boot*.
   (This writes a tiny image whose only job is to rewrite the EEPROM boot order.)
5. **Choose Storage** → the microSD card. Click **Write** and confirm.
6. Put the SD card into the **Pi (powered off)**, connect HDMI if you want to watch, and
   power on.
7. When done (~10 s) the screen turns **green** and the green activity LED blinks steadily
   in a repeating pattern. **Power off** the Pi and remove the SD card.
8. Repeat steps 5–7 for the second Pi (reuse the same SD card).

> The SD card is now free — it is not needed again. The OS lives on the SSD.

### 2.2 Flash Ubuntu Server onto the SSD (from your PC) — [ALL]

Do this once per SSD. Both SSDs get the same image; you differentiate them via hostname.

1. Connect the **SSD to your PC** (USB enclosure/adapter).
2. Open **Raspberry Pi Imager**.
3. **Choose Device** → *Raspberry Pi 4*.
4. **Choose OS** → *Other general-purpose OS* → *Ubuntu* →
   **Ubuntu Server 24.04 LTS (64-bit)** (ARM64). Do **not** pick the Desktop image.
5. **Choose Storage** → select the **SSD**.
   ⚠️ Double-check the device size so you don't overwrite the wrong disk.
6. Click **Next**, then **Edit Settings** (OS customisation) — this is what makes the node
   come up headless and ready:
   - **Set hostname:** `k8s-cp-1` for the control-plane node, `k8s-w1` for the worker.
   - **Enable SSH** → *Allow public-key authentication only* → paste your public key
     (`~/.ssh/id_ed25519.pub` or `id_rsa.pub`). This bakes in key auth from first boot.
   - **Set username and password:** e.g. user `ubuntu` (password is a fallback for console).
   - **Configure wireless LAN:** optional — skip it, since you'll use wired Ethernet.
   - **Locale / timezone:** set as appropriate.
7. **Save**, then **Write** and confirm. **Let the *Verifying* stage run to completion** —
   do not cancel it or unplug early. A dropped write is the #1 cause of a node that won't
   boot (see below).
8. Repeat steps 1–7 for the second SSD, using hostname `k8s-w1`.

> Ubuntu on the Pi uses **cloud-init**; the settings above are written into the boot
> partition and applied on first boot. No monitor/keyboard needed after this.

> ⚠️ **Use a reliable USB connection for flashing.** A flaky USB-SATA adapter or a marginal
> USB port can drop out mid-write, leaving the **boot partition written but the root
> partition empty**. The Pi then boots the kernel but drops to an `(initramfs)` shell with
> `ALERT! LABEL=writable does not exist`. If that happens, re-flash through a different USB
> port/adapter and let *Verifying* finish. See troubleshooting below to confirm the diagnosis.

> ⚠️ **Verbatim Portable SSD (this build) needs a UAS quirk.** The Verbatim bridge chip
> (`idVendor=18a5 idProduct=0468`) is driven in **UAS** mode by default, which is buggy on
> the Pi 4 and causes `uas_eh_abort_handler` / `Device offlined` I/O errors and boot failure
> (often a kernel panic). Fix on **both** SSDs: edit `cmdline.txt` on the FAT `system-boot`
> partition (readable from Windows) and append to the single line:
> `usb-storage.quirks=18a5:0468:u`. Verify after boot: `lsusb -t` shows `Driver=usb-storage`
> (not `uas`). Do this before joining the nodes to the cluster — UAS resets under k8s I/O
> load will otherwise make nodes flap.

### 2.3 First boot from SSD — [ALL]

1. Plug the SSD into one of the Pi's **blue USB 3.0** ports (not the black USB 2.0 ones —
   the SSD needs 3.0 for speed).
2. Connect wired Ethernet and power on. **First boot takes a few minutes** (cloud-init
   expands the filesystem and applies your settings), and the Pi may reboot once.
3. Find the node's IP (from your router's client list, or by hostname) and SSH in:

   ```bash
   ssh ubuntu@<NODE_IP>        # or: ssh ubuntu@k8s-cp-1.local
   ```

4. Update the system, then repeat for the second Pi:

   ```bash
   sudo apt update && sudo apt full-upgrade -y && sudo reboot
   ```

### 2.4 Assign a static IP (discover MAC, then pin) — [ALL]

You couldn't set this before boot because you didn't have the MAC yet. Now you do:

1. Read the node's MAC over SSH:

   ```bash
   cat /sys/class/net/eth0/address        # e.g. dc:a6:32:xx:xx:xx (Raspberry Pi OUI)
   ```

2. Pin the IP — pick **one** approach:
   - **DHCP reservation (recommended):** on your router, bind that MAC → chosen IP
     (`192.168.0.11` for CP, `192.168.0.12` for the worker), then reboot the Pi.
   - **Static via netplan on the Pi:**

     ```yaml
     # /etc/netplan/99-static.yaml
     network:
       version: 2
       ethernets:
         eth0:
           dhcp4: false
           addresses: [192.168.0.11/24]
           routes:
             - to: default
               via: 192.168.0.1
           nameservers:
             addresses: [192.168.0.1, 1.1.1.1]
     ```

     Then `sudo netplan apply`.

The Pi's MAC is fixed per unit, so this is a one-time step and survives reboots.

### 2.5 Confirm the EEPROM boot order (from the running OS) — [ALL]

Now that Ubuntu is up, verify/lock in USB-first so it stays that way:

```bash
sudo rpi-eeprom-config          # inspect current config
# BOOT_ORDER=0xf41  -> read right-to-left: 1 = SD, 4 = USB, f = repeat; tries USB first
```

If it isn't `0xf41`, set it:

```bash
sudo -E rpi-eeprom-config --apply <(rpi-eeprom-config | sed 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf41/')
sudo reboot
```

### 2.6 SSH hardening — [ALL]

Key auth is already on from 2.2; now disable password login entirely:

```bash
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

---

### 2.7 SSH client setup from WSL2 — [workstation]

If your SSH keys live under the Windows profile (e.g. `/mnt/c/Users/<you>/.ssh`), copy them
into WSL's native filesystem instead of using them in place — `/mnt/c` is a drvfs mount that
can't represent Unix permissions, so `sshd`/`ssh` reject a key there as too open.

```bash
mkdir -p ~/.ssh
cp "/mnt/c/Users/<you>/.ssh/k8s-pi"     ~/.ssh/
cp "/mnt/c/Users/<you>/.ssh/k8s-pi.pub" ~/.ssh/
cp "/mnt/c/Users/<you>/.ssh/known_hosts" ~/.ssh/   # carries over already-trusted host keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/k8s-pi
chmod 644 ~/.ssh/k8s-pi.pub ~/.ssh/known_hosts
```

Then create `~/.ssh/config` (WSL-native, `chmod 600`) with the same host entries used on the
Windows side:

```
Host k8s-cp-1
    HostName 192.168.1.11
    User ubuntu
    IdentityFile ~/.ssh/k8s-pi

Host k8s-w-1
    HostName 192.168.1.21
    User ubuntu
    IdentityFile ~/.ssh/k8s-pi
```

Now `ssh k8s-cp-1` / `ssh k8s-w-1` work directly.

**Running the same command on both nodes at once** — use tmux's synchronized-panes: split a
window into two panes, SSH into each host, then mirror keystrokes across both.

```bash
tmux new-session -d -s k8s -x 220 -y 50 \; \
  send-keys 'ssh k8s-cp-1' C-m \; \
  split-window -h \; \
  send-keys 'ssh k8s-w-1' C-m \; \
  set-window-option synchronize-panes on
tmux attach -t k8s
```

- Toggle sync: `Ctrl-b :` then `set synchronize-panes on` / `off` — turn it **off** before
  anything host-specific (e.g. checking `hostname`).
- Switch panes: `Ctrl-b` + arrow key. Detach: `Ctrl-b d`. Kill session: `tmux kill-session -t k8s`.

---

## 3. Node prerequisites — [ALL]

```bash
# conntrack: kubeadm preflight checks require it (kube-proxy uses it for connection
# tracking) but it's not pulled in by containerd or the kubelet/kubeadm packages, so
# it has to be installed explicitly or `kubeadm init`/`join` fails preflight.
sudo apt update
sudo apt install -y conntrack

# Disable swap (kubelet requires it — with swap on, the kubelet either refuses to
# start or (pre-1.22 semantics aside) memory accounting/eviction gets unreliable)
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
# On Ubuntu 24.04 zram-swap may also be active — it's still swap, so kubelet sees
# the same problem even after the line above:
sudo systemctl disable --now zramswap.service 2>/dev/null || true

# Kernel modules:
#   overlay      — containerd stores image/container layers on OverlayFS
#   br_netfilter — makes bridged traffic (pod-to-pod via the CNI bridge) visible
#                  to iptables, otherwise kube-proxy's rules never see it
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl: the two bridge-nf settings pair with br_netfilter above (iptables must
# actually inspect bridged packets), and ip_forward lets the node route packets
# between pods/nodes instead of just its own processes.
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

> **cgroup memory** — on the Pi the memory cgroup is sometimes not enabled. Check:
> `cat /sys/fs/cgroup/cgroup.controllers` — if `memory` is missing, append to the end of
> `/boot/firmware/cmdline.txt` (single line):
> `cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1`, then `sudo reboot`.

---

## 4. Container runtime — containerd — [ALL]

kubelet doesn't run containers itself — it talks to a CRI-compatible runtime, and
containerd is that runtime here.

```bash
sudo apt update
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
# The apt package ships with no config file at all, so generate the shipped
# defaults first — skipping this is exactly what breaks the sed below (no file
# to edit). See the config-toml troubleshooting note if you hit that.
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
# systemd cgroup driver (required by kubelet) — Ubuntu's init system is systemd,
# so kubelet and the container runtime both need to manage cgroups the same way;
# a mismatch here is a classic cause of kubelet failing to start.
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

---

## 5. kubeadm, kubelet, kubectl — [ALL]

Ubuntu's own repos don't carry current Kubernetes packages, so this adds the
upstream `pkgs.k8s.io` apt repo (GPG-signed, so apt can verify what it installs)
and pulls the three binaries from there instead.

```bash
sudo apt install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

> `v1.31` is the repo minor — check whether it's still supported and bump to the latest
> stable minor if needed (the keyring URL must be changed to the same version). The
> `apt-mark hold` prevents accidental upgrades.

---

## 6. Cluster bootstrap

### 6.1 Control-plane init — [CP]

`kubeadm init` stands up etcd, the API server, scheduler and controller-manager
as static pods on this node. `--pod-network-cidr` must match what the CNI
(Calico, next step) expects, and pinning `--apiserver-advertise-address`
avoids kubeadm guessing the wrong NIC on a multi-interface host.

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=<CP_IP>

# kubeconfig for your user — admin.conf is written root-owned; kubectl reads
# $HOME/.kube/config by default, so copy it out and hand it to your own user
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

`init` prints a `kubeadm join ...` command with a token at the end — save it for the
worker node.

### 6.2 CNI — Calico — [CP]

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

> Since we're not using Calico's default `192.168.0.0/16` (we chose `10.244.0.0/16`),
> Calico picks up the pod CIDR from `kubeadm` via the installed manifest, so extra config
> is usually not needed. Verify: `kubectl get pods -n kube-system` — the `calico-node`
> pods should be `Running`.

### 6.3 Worker join — [W]

The token and CA cert hash let the worker's kubelet authenticate to the API
server and complete TLS bootstrap without you manually distributing certs.

```bash
# command copied from the 6.1 output, as root:
sudo kubeadm join <CP_IP>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

If the token expired, generate a new one on [CP]: `kubeadm token create --print-join-command`.

### 6.4 Remove taint (2-node cluster) — [CP]

So the control-plane also schedules pods (otherwise half of the 2 nodes is unused):

```bash
kubectl taint nodes <control-plane-node-name> node-role.kubernetes.io/control-plane:NoSchedule-
```

Verify:

```bash
kubectl get nodes -o wide      # both Ready
```

---

## 7. Storage

A bare-metal cluster has no cloud disk API to satisfy PVCs automatically, so one
of these two provisioners has to fill that role.

### Option A — local-path-provisioner (simple, node-local)

Provisions a PV as a plain directory on whichever node the pod happens to land
on — no replication, but nothing extra to run. Fine for a home lab where
losing one node's local data is acceptable.

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Option B — Longhorn (replicated across nodes)

Replicates volumes across nodes so a single SSD/node failure doesn't lose data —
the tradeoff is it runs its own storage stack on top of Kubernetes.

Prerequisite — [ALL]: Longhorn's data path talks to storage over iSCSI, and can
also export NFS-backed volumes, so both clients need to already be installed.

```bash
sudo apt install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

Install on [CP] (Helm or manifest). With 2 nodes set the replica count to `2` so each SSD
holds a copy.

### 7.1 Longhorn backups → S3 — [CP]

Replication (above) only protects against a single node/SSD failing — it doesn't help if
the whole cluster goes down (both Pis, a bad `kubectl apply`, a corrupted volume). Longhorn
has a built-in S3 backup target, so volume snapshots ship off both SSDs entirely.

1. **S3 bucket + a scoped IAM user** — run once, from your PC with the AWS CLI configured.
   A dedicated user with access to only this bucket limits the blast radius if the key ever
   leaks:

   ```bash
   aws s3api create-bucket --bucket <your-bucket> --region <region> \
     --create-bucket-configuration LocationConstraint=<region>

   aws iam create-user --user-name longhorn-backup
   aws iam put-user-policy --user-name longhorn-backup --policy-name longhorn-s3-backup \
     --policy-document '{
       "Version": "2012-10-17",
       "Statement": [{
         "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
         "Resource": ["arn:aws:s3:::<your-bucket>", "arn:aws:s3:::<your-bucket>/*"]
       }]
     }'
   aws iam create-access-key --user-name longhorn-backup   # save the AccessKeyId/SecretAccessKey
   ```

2. **Give Longhorn the credentials**, as a Secret in its own namespace — never on an SSD in
   plaintext outside the cluster:

   ```bash
   kubectl -n longhorn-system create secret generic longhorn-s3-backup \
     --from-literal=AWS_ACCESS_KEY_ID=<access-key-id> \
     --from-literal=AWS_SECRET_ACCESS_KEY=<secret-access-key>
   ```

3. **Point Longhorn at the bucket** by setting the backup target (Settings → General in the
   Longhorn UI, or via `kubectl`):

   ```bash
   kubectl -n longhorn-system patch settings.longhorn.io backup-target \
     --type merge -p '{"value":"s3://<your-bucket>@<region>/backupstore"}'
   kubectl -n longhorn-system patch settings.longhorn.io backup-target-credential-secret \
     --type merge -p '{"value":"longhorn-s3-backup"}'
   ```

4. **Schedule recurring backups** with a `RecurringJob` — without one, backups only happen
   when you trigger them by hand:

   ```yaml
   # recurringjob-daily-backup.yaml
   apiVersion: longhorn.io/v1beta2
   kind: RecurringJob
   metadata:
     name: daily-backup
     namespace: longhorn-system
   spec:
     cron: "0 3 * * *"    # 03:00 daily, off-hours
     task: backup
     groups:
       - default
     retain: 7             # keep the last 7 backups in S3
     concurrency: 2
   ```

   ```bash
   kubectl apply -f recurringjob-daily-backup.yaml
   ```

   Volumes only get backed up if they're in the job's group. Add the group to the
   StorageClass so every future PVC is covered automatically, rather than labelling
   volumes one by one:

   ```bash
   kubectl patch storageclass longhorn \
     -p '{"parameters":{"recurringJobSelector":"[{\"name\":\"daily-backup\",\"isGroup\":true}]"}}'
   ```

5. **Verify** — after the first scheduled run (or trigger one manually from the Longhorn
   UI), confirm the backup landed:

   ```bash
   kubectl -n longhorn-system get backups.longhorn.io
   aws s3 ls s3://<your-bucket>/backupstore/ --recursive
   ```

> An untested backup isn't a backup. Periodically restore a volume from S3 into a scratch
> PVC (Longhorn UI → Backup → Restore) to confirm the whole path actually works, not just
> that objects are landing in the bucket.

---

## 8. Networking / add-ons — [CP]

### MetalLB (LoadBalancer IPs on the LAN)

On a cloud cluster, `Service type: LoadBalancer` asks the cloud provider for a
real IP; bare metal has no provider to ask, so `LoadBalancer` Services just
hang in `Pending` forever without something to fill that role. MetalLB does —
it hands out IPs from a pool you define and announces them on the LAN (ARP/L2
here) so they're reachable from other devices on the network.

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
```

Then an IP pool from the free range of the LAN:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: home-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.0.240-192.168.0.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: home-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - home-pool
```

### ingress-nginx

Without an ingress controller, every HTTP service you want to expose needs its
own MetalLB IP. ingress-nginx gives you one entrypoint IP and routes by
hostname/path to whichever internal Service each request is for.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
```

The `ingress-nginx-controller` Service will be of type `LoadBalancer` and gets an IP from
the MetalLB pool.

---

## 9. GitOps — Flux CD — [CP]

Flux watches a git repo and continuously reconciles the cluster to match what's
committed, so `git push` becomes the deploy mechanism instead of manual
`kubectl apply` — and cluster state stays reviewable/revertible via git history.

```bash
curl -s https://fluxcd.io/install.sh | sudo bash

flux bootstrap github \
  --owner=<gh-user> \
  --repository=<repo> \
  --branch=main \
  --path=clusters/home-lab \
  --personal
```

- Bootstrap against the same git repo you use on AKS, under a separate `clusters/` path
  (`clusters/aks`, `clusters/home-lab`).
- Shared manifests (`apps/`, `infrastructure/`) are portable between the two environments
  via Kustomize overlays; the home-lab overlay covers Pi-specific differences (ARM64
  images, local-path/Longhorn storage class, MetalLB).

---

## 10. Monitoring / maintenance

```bash
# Temperature under load (throttle threshold 80 °C)
vcgencmd measure_temp

# Whether throttling occurred (0x0 = no)
vcgencmd get_throttled
```

- If it stays **above 70 °C** → consider switching to dual fan.
- Node status: `kubectl get nodes`, `kubectl top nodes` (after installing metrics-server).
- Regular `apt upgrade` — but `kubelet/kubeadm/kubectl` are on `hold`; upgrade those
  deliberately, per version, by hand (following the `kubeadm upgrade` workflow).

## Check Pimoroni fan shim service
```bash
sudo systemctl status pimoroni-fanshim.service
```
---

## Troubleshooting — common spots

| Symptom | Cause / fix |
|---|---|
| `kubeadm init` fails on cgroup | memory cgroup not enabled → section 3, cmdline.txt |
| Pods `Pending`, CNI won't start | Calico manifest pod CIDR ≠ `kubeadm --pod-network-cidr` |
| Weird routing / service unreachable | pod CIDR overlaps the LAN → section 0 |
| Worker won't join | token expired → `kubeadm token create --print-join-command` |
| Node `NotReady` after restart | swap re-enabled / zram → section 3 |
| Boot drops to `(initramfs)`, `ALERT! LABEL=writable does not exist` | Root partition has no filesystem — incomplete flash. Confirm at the shell: `ls /dev/sda*` shows `sda2`, but `blkid` lists `sda2` with **only a PARTUUID** (no `TYPE`/`LABEL`). Fix: re-flash through a good USB port/adapter, let *Verifying* finish. |
| Boot reaches multi-user but many services (`rsyslog`, `snapd`, `systemd-logind`, `cloud-final`) fail together | Same partial/corrupt flash — root fs is incomplete. Re-flash cleanly. |
| `Kernel panic — Attempted to kill init`, or `uas_eh_abort_handler` / `Device offlined` / `EXT4-fs error` / `Data phase error` I/O errors on `sda` | USB bridge driven in buggy **UAS** mode (Verbatim `18a5:0468` here — check `dmesg` for `scsi host: uas`). **Disable UAS** via `cmdline.txt`: append `usb-storage.quirks=18a5:0468:u` (use *your* VID:PID from `lsusb` if a different drive). Also ensure a genuine 5V/3A+ PSU. If it persists on good power with UAS off, the adapter is faulty — replace it. |
| Verified flash still drops to initramfs (`blkid` *does* show `sda2` as `ext4 LABEL="writable"`) | Genuine USB enumeration race. Edit `cmdline.txt` on the FAT `system-boot` partition (readable from Windows), append on the single line: `rootdelay=10 usb-storage.quirks=VID:PID:u` (VID:PID from `lsusb` / Windows Device Manager). |
