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

## 3. Node prerequisites — [ALL]

```bash
# Disable swap (kubelet requires it)
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
# On Ubuntu 24.04 zram-swap may also be active:
sudo systemctl disable --now zramswap.service 2>/dev/null || true

# Kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl (bridge + IP forward)
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

```bash
sudo apt update
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
# systemd cgroup driver (required by kubelet)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

---

## 5. kubeadm, kubelet, kubectl — [ALL]

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

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=<CP_IP>

# kubeconfig for your user
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

### Option A — local-path-provisioner (simple, node-local)

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Option B — Longhorn (replicated across nodes)

Prerequisite — [ALL]:

```bash
sudo apt install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

Install on [CP] (Helm or manifest). With 2 nodes set the replica count to `2` so each SSD
holds a copy.

---

## 8. Networking / add-ons — [CP]

### MetalLB (LoadBalancer IPs on the LAN)

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

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
```

The `ingress-nginx-controller` Service will be of type `LoadBalancer` and gets an IP from
the MetalLB pool.

---

## 9. GitOps — Flux CD — [CP]

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
