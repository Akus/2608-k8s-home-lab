# Shared helpers for the runbook scripts. Sourced, not run:
#   source "$(dirname "$0")/../lib.sh"
set -uo pipefail

INGRESS_IP=192.168.1.240   # ingress-nginx's MetalLB IP
WORKER=k8s-w-1             # SSH host alias from IMPLEMENTATION.md §2.7
CONTROL_PLANE=k8s-cp-1

fails=0
pass() { printf '  \e[32mPASS\e[0m %s\n' "$1"; }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$1"; fails=$((fails + 1)); }

# check "description" cmd args...      passes if the command succeeds
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
# check_not "description" cmd args...  passes if the command fails
check_not() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi; }
# check_eq "description" expected actual
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

summary() {
  echo
  if ((fails == 0)); then echo "All checks passed."; else echo "$fails check(s) failed."; exit 1; fi
}

# http_code URL [curl args...]: prints the status code, 000 if unreachable
http_code() { curl -s -m 5 -o /dev/null -w '%{http_code}' "$@" || true; }

# selector NS DEPLOYMENT: the Deployment's matchLabels as "k=v,k=v", for `kubectl get pods -l`
selector() {
  kubectl -n "$1" get deploy "$2" \
    -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null |
    sed 's/,$//'
}

ensure_ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }
