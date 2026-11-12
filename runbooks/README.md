# Runbooks: hands-on practice on the home lab

Killercoda-style exercises against the real cluster. Each one has a task, a script that checks
your work, and hints and a solution folded away at the bottom of its README.

```bash
cd runbooks/10-pods-not-starting
./setup.sh      # if present: creates the scenario (often a broken one)
# ...work on it with kubectl, ssh, logs, docs...
./verify.sh     # PASS/FAIL per acceptance criterion, run as often as you like
./cleanup.sh    # removes everything the scenario created
```

Rules of the game:
- Don't read `setup.sh` before you're done; it's the answer key for troubleshooting tasks.
- Work from the symptoms: `kubectl get`, `describe`, `logs`, `events`, `journalctl`.
  Official docs (kubernetes.io) are allowed, like in the CKA.
- Practice scenarios live in their own namespace (`rb-NN`) and never touch `hil-lab`,
  `kube-system` or the add-ons. The **real cluster** ones say so at the top; read their
  warnings before starting.

## Build and deploy

| # | Scenario | Skills |
|---|---|---|
| [01](01-deploy-web-app/) | Deploy a web app behind the ingress | Deployment, probes, resources, spread, Service, Ingress |
| [02](02-stateful-postgres/) | Run Postgres with persistent storage | StatefulSet, PVC, Secret, data survives pod loss |
| [03](03-rollout-rollback/) | A bad release is half rolled out | rollout history, undo, change-cause |
| [04](04-rbac-ci-deployer/) | Least-privilege account for a CI pipeline | ServiceAccount, Role, RoleBinding, tokens, kubeconfig |

## Troubleshooting

| # | Scenario | Skills |
|---|---|---|
| [10](10-pods-not-starting/) | Three pods that won't start | ImagePullBackOff, CreateContainerConfigError, OOMKilled |
| [11](11-pods-pending/) | Three pods stuck Pending | scheduling, requests, nodeSelector, StorageClass |
| [12](12-service-no-endpoints/) | Service reachable but nothing answers | selectors, targetPort, readiness, EndpointSlices |
| [13](13-ingress-not-routing/) | Ingress returns 404/503 | IngressClass, backend ports, hosts |
| [14](14-networkpolicy/) | Locked-down namespace, open one path | NetworkPolicy, DNS egress |
| [15](15-hpa-unknown/) | Autoscaler shows `<unknown>` | HPA, metrics-server, requests |
| [16](16-node-notready/) | **Real cluster:** worker is NotReady | kubelet, journalctl, swap |

## Operations

All of these run against the **real cluster**.

| # | Scenario | Skills |
|---|---|---|
| [20](20-drain-node/) | Take the worker down for maintenance | cordon, drain, PDBs, node-local storage |
| [21](21-etcd-backup/) | Back up etcd (and optionally restore) | etcdctl snapshot, static pods |
| [22](22-kubeadm-upgrade/) | Upgrade Kubernetes one minor version | kubeadm upgrade, apt repos, drain order |
| [23](23-certificates/) | Check and renew certificates | kubeadm certs, kubeconfig, cert-manager |
| [24](24-addon-upgrade/) | Upgrade an add-on and roll back | release notes, kubectl diff, patches that get lost |
| [25](25-chaos-game-day/) | Chaos game day + postmortem | Litmus, Grafana, hypotheses, write-up |

Suggested order: 01 → 10 → 11 → 12 → 13 → 02 → 03 → 14 → 15 → 04, then the real-cluster
ones. Do 21 (etcd backup) before 22 (upgrade).
