# 25: Chaos game day + postmortem (real cluster)

> **Real cluster.** You inject real faults into the HIL lab (`hil-lab`) with LitmusChaos
> (IMPLEMENTATION.md §8). Every experiment has a fixed duration and cleans up after itself;
> to abort early: `kubectl -n hil-lab patch chaosengine <name> --type=merge -p '{"spec":{"engineState":"stop"}}'`.

A game day is a chaos experiment run like an incident drill: you write down what you
**expect** before breaking anything, then compare with what really happened. The value is
in the gaps between the two.

## Task

Run at least two experiments. For each one, fill in a copy of
[`postmortem-template.md`](postmortem-template.md) under `runbooks/25-chaos-game-day/notes/`
(gitignored).

**Experiment A: rig-api dies repeatedly.** The engine already exists:
`clusters/home-lab/litmus/hil-lab/engines/pod-delete-rig-api.yaml`.
- Hypothesis first: how long is the rig API unavailable each time? What do Jenkins builds
  that are running at that moment do? Which alerts should fire?

**Experiment B: the network to one rig gets slow.** Write a new engine,
`engines/pod-network-latency-rig-vienna-01.yaml`, that adds 2 s of latency to
`rig-vienna-01` for 2 minutes.
- Hypothesis first: does the broker mark the rig `UNREACHABLE`? After how long? Does
  `RigUnreachableByBroker` fire (see the lab repo's `alerts.yml`)? What happens to a
  pipeline that has this rig reserved?

For both: watch it live in Grafana (`grafana.home.lan` / `grafana.lab.akos-demo.com`), the
rig fleet dashboard, and in Prometheus' Alerts page. Check the Litmus verdict afterwards.

Stretch goals:
- Start a Jenkins pipeline right before the experiment, so the fault hits a running build.
- Experiment C of your own choice: `pod-cpu-hog` on Jenkins, `pod-memory-hog` on
  Prometheus, or `pod-network-loss` on rig-api.
- Turn a finding into a fix (a probe, an alert, a retry, a second replica) and run the
  experiment again to prove it.

<details><summary>Hints</summary>

- Copy `pod-delete-rig-api.yaml` and change `experiments[].name` to `pod-network-latency`,
  the `applabel` to the rig's label (`kubectl -n hil-lab get deploy rig-vienna-01 --show-labels`),
  and the env vars. The fault's options and their defaults:
  `kubectl -n hil-lab get chaosexperiment pod-network-latency -o yaml`.
- Litmus runs a runner pod, an experiment pod and a helper pod in `hil-lab`. If the verdict
  isn't `Pass`, their logs say why: `kubectl -n hil-lab get pods -l chaosUID`.
- The engine name must be deleted before re-running: `kubectl -n hil-lab delete chaosengine <name>`.
- Without an Alertmanager (TODO.md, "Prometheus alerts"), alerts only show up on
  Prometheus' Alerts page, not as notifications. That's a finding worth writing down.

</details>

<details><summary>Example engine for Experiment B</summary>

```yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: latency-rig-vienna-01
  namespace: hil-lab
spec:
  engineState: active
  appinfo:
    appns: hil-lab
    applabel: app.kubernetes.io/name=rig-vienna-01
    appkind: deployment
  chaosServiceAccount: litmus-admin
  jobCleanUpPolicy: delete
  experiments:
    - name: pod-network-latency
      spec:
        components:
          env:
            - { name: NETWORK_LATENCY, value: "2000" }       # ms
            - { name: TOTAL_CHAOS_DURATION, value: "120" }   # s
            - { name: NETWORK_INTERFACE, value: eth0 }
            - { name: CONTAINER_RUNTIME, value: containerd }
            - { name: SOCKET_PATH, value: /run/containerd/containerd.sock }
```

```bash
kubectl apply -f clusters/home-lab/litmus/hil-lab/engines/pod-network-latency-rig-vienna-01.yaml
kubectl -n hil-lab get chaosresult latency-rig-vienna-01-pod-network-latency \
  -o jsonpath='{.status.experimentStatus.verdict}'
```

The helper pod needs privileges to enter the rig's network namespace. If it fails with a
permission error, that's the namespaced Role in `litmus/hil-lab/rbac.yaml` or a Pod
Security level on `hil-lab`; the helper's logs say which.

</details>
