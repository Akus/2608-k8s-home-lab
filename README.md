# Kubernetes Home Lab — 2× Raspberry Pi 4B (8GB)

Kubeadm-based, 2-node Kubernetes cluster on Raspberry Pi 4B, booting from Verbatim SSDs
(USB boot). The GitOps layer (Flux CD) follows the same pattern used on AKS, so manifests
and workflow stay portable between the cloud and the home lab.

## What's in it

| Layer | Choice |
|---|---|
| OS | Ubuntu Server 24.04 LTS (ARM64), SSD boot (USB) |
| Runtime | containerd (`SystemdCgroup = true`) |
| Cluster | kubeadm, 1 control-plane + 1 worker (taint removed → both schedule) |
| CNI | Calico |
| Storage | local-path-provisioner (simple) or Longhorn (replicated) |
| Networking | MetalLB (LoadBalancer IPs) + ingress-nginx |
| GitOps | Flux CD |

## Hardware

| Component | Qty | Notes |
|---|---|---|
| Raspberry Pi 4 Model B (8GB) | 2 | Broadcom BCM2711, quad-core Cortex-A72, 8GB LPDDR4 |
| Verbatim SSD | 2 | USB 3.0 boot, 1 per node |
| Cooling | 2× single fan + alu heatsink | dual fan only if airflow is tight |
| micro-HDMI → HDMI adapter | 1 | initial setup only, then headless/SSH |

> **Networking:** wired Gigabit Ethernet between nodes is recommended (on the Pi 4B it's
> on a dedicated bus, not shared with USB) — more stable and lower latency than WiFi.

## Quick overview

1. Prepare SSD boot: update the bootloader via SD card (USB boot), flash Ubuntu onto the
   SSD with Raspberry Pi Imager, first boot + SSH key.
2. Node prerequisites: disable swap, kernel modules, sysctl.
3. Install containerd + kubeadm/kubelet/kubectl on both nodes.
4. `kubeadm init` on the control-plane, Calico CNI, worker `join`, remove taint.
5. Storage + MetalLB + ingress-nginx.
6. Flux CD bootstrap against the shared git repo.

Full, command-by-command walkthrough: **[IMPLEMENTATION.md](IMPLEMENTATION.md)**.

## Buying

- Cooling, cases: pi-shop.hu, rpibolt.hu, malnapc.hu
- micro-HDMI adapter/cable, SSD: alza.hu (brand doesn't matter for a plain adapter)
