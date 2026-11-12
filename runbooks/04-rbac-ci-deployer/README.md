# 04: Least-privilege account for a CI pipeline

```bash
./setup.sh     # just creates namespace rb-04
```

## Task

A CI pipeline will deploy into `rb-04` and should be able to do nothing else.

1. ServiceAccount `ci-deployer` in `rb-04`.
2. In `rb-04` it can **get, list, watch, create, update and patch** Deployments, and
   **read** pods and their logs.
3. It can **not**: delete Deployments, read Secrets, touch any other namespace (e.g.
   `hil-lab`), or see cluster-wide objects like nodes.
4. A kubeconfig file `ci-deployer.kubeconfig` in this directory that authenticates as the
   ServiceAccount with a token valid for **1 hour**, so you can hand it to "the pipeline".
   It's gitignored. Don't commit tokens.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- `kubectl create role --verb=... --resource=...` and `kubectl create rolebinding --role=... --serviceaccount=rb-04:ci-deployer`.
- Test without a kubeconfig: `kubectl auth can-i delete deployments -n rb-04 --as=system:serviceaccount:rb-04:ci-deployer`,
  or the whole list with `kubectl auth can-i --list -n rb-04 --as=...`.
- `kubectl create token ci-deployer -n rb-04 --duration=1h` issues a short-lived token.
  Since 1.24, ServiceAccounts no longer get a long-lived token Secret automatically.
- Build the kubeconfig with `kubectl config --kubeconfig=ci-deployer.kubeconfig set-cluster/set-credentials/set-context/use-context`.
  The cluster's CA and server URL are in your own kubeconfig (`kubectl config view --raw --minify`).

</details>

<details><summary>Solution</summary>

```bash
kubectl -n rb-04 create serviceaccount ci-deployer
kubectl -n rb-04 create role ci-deployer \
  --verb=get,list,watch,create,update,patch --resource=deployments.apps
kubectl -n rb-04 patch role ci-deployer --type=json -p='[{"op":"add","path":"/rules/-",
  "value":{"apiGroups":[""],"resources":["pods","pods/log"],"verbs":["get","list","watch"]}}]'
kubectl -n rb-04 create rolebinding ci-deployer --role=ci-deployer --serviceaccount=rb-04:ci-deployer

server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/ca.crt
K="kubectl config --kubeconfig=ci-deployer.kubeconfig"
$K set-cluster home-lab --server="$server" --certificate-authority=/tmp/ca.crt --embed-certs
$K set-credentials ci-deployer --token="$(kubectl -n rb-04 create token ci-deployer --duration=1h)"
$K set-context ci --cluster=home-lab --user=ci-deployer --namespace=rb-04
$K use-context ci
rm /tmp/ca.crt

kubectl --kubeconfig=ci-deployer.kubeconfig auth whoami
kubectl --kubeconfig=ci-deployer.kubeconfig get deploy        # works (empty)
kubectl --kubeconfig=ci-deployer.kubeconfig get secrets       # Forbidden
```

A Role plus RoleBinding is namespaced by construction. Even a ClusterRole bound with a
RoleBinding only applies inside that namespace. Only a ClusterRoleBinding grants
cluster-wide access.

</details>
