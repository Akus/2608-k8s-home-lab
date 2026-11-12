#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
dir="$(dirname "$0")/backups"
echo "21: etcd backup"

snap=$(ls -t "$dir"/*.db 2>/dev/null | head -1)
check "a snapshot exists in backups/" test -n "$snap"
if [[ -n "$snap" ]]; then
  check "it is less than 24 h old" test -n "$(find "$snap" -mmin -1440)"
  check "it is larger than 1 MB" test "$(stat -c %s "$snap")" -gt 1000000
  name=$(basename "$snap")
  remote=$(ssh -o BatchMode=yes "$CONTROL_PLANE" "sudo sha256sum /var/lib/etcd/$name 2>/dev/null" | cut -d' ' -f1)
  check_eq "it matches /var/lib/etcd/$name on $CONTROL_PLANE" "${remote:-<missing on node>}" \
    "$(sha256sum "$snap" | cut -d' ' -f1)"
  status=$(kubectl -n kube-system exec "etcd-$CONTROL_PLANE" -- etcdutl snapshot status "/var/lib/etcd/$name" -w json 2>/dev/null)
  check "etcdutl reads it as a valid snapshot ($status)" test -n "$status"
fi
check "PKI backup backups/pki.tgz contains ca.key" bash -c "tar tzf '$dir/pki.tgz' 2>/dev/null | grep -q 'pki/ca.key'"
summary
