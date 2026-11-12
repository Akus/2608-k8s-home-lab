# 13: Ingress returns 404/503

```bash
./setup.sh
```

## Situation

The `web` app in `rb-13` should be served at `web.rb.lan` through ingress-nginx. The
pod is running and the Service works from inside the cluster, but from your laptop:

```bash
curl -sv -H 'Host: web.rb.lan' http://192.168.1.240/     # 404 from nginx
```

## Task

Make that `curl` return the nginx welcome page (HTTP 200). Change only the **Ingress**: the
Deployment and Service are owned by another team and are fine.

```bash
./verify.sh
./cleanup.sh
```

<details><summary>Hints</summary>

- `kubectl -n rb-13 get ingress web`: is the ADDRESS column filled in? What does CLASS say?
- `kubectl get ingressclass`, and look for the `ingressclass.kubernetes.io/is-default-class`
  annotation. Without a default, which controller picks up an Ingress with no class?
- The controller's view: `kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=50`.
- A 404 from ingress-nginx means no rule matched the request's host/path. A 503 means a rule
  matched but the backend has no usable endpoints. Which one do you get after each fix?
- `kubectl -n rb-13 describe ingress web` shows the backend it resolved to, with an
  error if the Service port doesn't exist.

</details>

<details><summary>Solution</summary>

1. **No class**: the cluster has no default IngressClass, and ingress-nginx ignores
   Ingresses without `ingressClassName` (`--watch-ingress-without-class` is off), so nothing
   serves it and ADDRESS stays empty. Add `ingressClassName: nginx`.
2. **Wrong host**: the rule is for `web.rb.local`, the request is for `web.rb.lan`, still 404.
3. **Wrong backend port**: the Ingress points at Service port `80`, but the Service exposes
   `8080` (80 is only its targetPort). Now 503. Ingress backends use the **Service** port.

```bash
kubectl -n rb-13 patch ingress web --type=json -p='[
  {"op":"add","path":"/spec/ingressClassName","value":"nginx"},
  {"op":"replace","path":"/spec/rules/0/host","value":"web.rb.lan"},
  {"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":8080}]'
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: web.rb.lan' http://192.168.1.240/
```

</details>
