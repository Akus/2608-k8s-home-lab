# Ansible: node prep + kubeadm bootstrap

Automates IMPLEMENTATION.md §3–6 (prereqs, containerd, kubeadm, init, Calico, join, untaint).
Everything above the cluster (MetalLB, ingress, apps) is handled by Flux, not here.

```bash
pip install ansible            # or: sudo apt install ansible
ansible-galaxy collection install -r requirements.yml
ansible all -m ping
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --check --diff   # dry run (init/join steps will report skipped/changed)
ansible-playbook site.yml
```

Admin kubeconfig is fetched to `~/.kube/config-home-lab` (`export KUBECONFIG=...`).

Tasks are idempotent: `kubeadm init` / `join` are guarded by `creates:`, so re-running on the
live cluster is a no-op apart from package/config drift. The first run on a node that is
missing the cgroup args in `cmdline.txt` will reboot it.

Tunables (k8s minor, pod CIDR, cmdline args, Calico version) are in `group_vars/all.yml`.
Hardware-specific `cmdline.txt` tweaks (UAS quirk, `rootdelay`) go in `cmdline_args`.
The Pimoroni fan shim install is not automated (see IMPLEMENTATION.md).
