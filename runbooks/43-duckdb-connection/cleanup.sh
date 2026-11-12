#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="$HERE/.port-forward.pid"

if [[ -f "$PIDFILE" ]]; then
  while read -r pid; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done < "$PIDFILE"
  rm -f "$PIDFILE"
fi
rm -f "$HERE"/.pf-*.log "$HERE/init.local.sql"
echo "Port-forwards started by setup.sh stopped, init.local.sql (live credentials) removed."
echo "Forwards you started yourself are left alone — check with: ss -ltn | grep -E ':8181|:3900'"
