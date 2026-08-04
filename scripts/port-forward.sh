#!/usr/bin/env bash
# =============================================================================
# port-forward.sh — Start background port-forwards for all demo services
# =============================================================================
# Writes PIDs to /tmp/devsecops-pf.pids so uninstall.sh can kill them.
# Safe to re-run: kills any existing port-forwards from a previous run first.
#
# Services forwarded:
#   localhost:30500 → registry/registry:5000
#   localhost:30300 → rekor-system/rekor-server:80
#   localhost:30200 → fulcio-system/fulcio-server:80
#   localhost:30100 → tuf-system/tuf-server:80
#   localhost:39000 → pki/devsecops-demo-stepca:9000
#   localhost:30800 → registry/registry-ui:80     (registry browser UI)
#   localhost:30900 → registry/rekor-ui:8080       (Rekor Search UI)
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PID_FILE="/tmp/devsecops-pf.pids"

info()  { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()    { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
fail()  { printf "  ${RED}[ERROR]${NC} %s\n" "$1"; }

printf "\n${CYAN}=== Starting port-forwards ===${NC}\n"

# Kill any existing port-forwards from a previous run
if [[ -f "$PID_FILE" ]]; then
  info "Stopping existing port-forwards ..."
  while IFS= read -r pid; do
    kill "$pid" 2>/dev/null && info "Killed PID $pid" || true
  done < "$PID_FILE"
  rm -f "$PID_FILE"
fi

# Helper: start a background port-forward and record the PID
pf() {
  local local_port="$1"
  local namespace="$2"
  local service="$3"
  local remote_port="$4"
  local label="$5"

  info "Forwarding $label: localhost:$local_port → $namespace/$service:$remote_port"

  # Wait for the service to exist before forwarding
  local max_wait=120
  local waited=0
  while ! kubectl get svc "$service" -n "$namespace" &>/dev/null; do
    if [[ "$waited" -ge "$max_wait" ]]; then
      fail "Service $namespace/$service not found after ${max_wait}s — skipping port-forward"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done

  # Wait for the Service to have at least one ready endpoint. `kubectl port-forward
  # svc/...` attaches to a backing pod and dies immediately if that pod is not
  # running (e.g. still pulling its image — "pod is not running. Current
  # status=Pending"). Bounded; if no endpoint ever appears we warn and skip
  # rather than hang the whole script (e.g. a UI whose image was never built).
  local ep_wait=90
  local ep_waited=0
  while [ -z "$(kubectl get endpoints "$service" -n "$namespace" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]; do
    if [[ "$ep_waited" -ge "$ep_wait" ]]; then
      fail "Service $namespace/$service has no ready endpoints after ${ep_wait}s — skipping port-forward"
      return 0
    fi
    sleep 3
    ep_waited=$((ep_waited + 3))
  done

  kubectl port-forward "svc/$service" "$local_port:$remote_port" \
    -n "$namespace" \
    >/tmp/pf-${service}.log 2>&1 &
  local pid=$!
  echo "$pid" >> "$PID_FILE"
  ok "  PID $pid — localhost:$local_port → $namespace/$service:$remote_port"
}

# Start all port-forwards
pf 30500 registry       registry          5000  "Docker Registry"
pf 30300 rekor-system   rekor-server      80    "Rekor"
pf 30200 fulcio-system  fulcio-server     80    "Fulcio"
pf 30100 tuf-system     tuf-server        80    "TUF mirror"
pf 39000 pki            devsecops-demo-stepca 9000  "step-ca"

# Demo web UIs (enabled by default; if you disable registryUi/rekorUi in values
# the pf helper waits for the Service then skips it).
pf 30800 registry       registry-ui       80    "Registry UI"
pf 30900 registry       rekor-ui          8080  "Rekor Search UI"

echo ""
info "Port-forward logs: /tmp/pf-<service>.log"
info "PID file: $PID_FILE"
info "To stop: bash scripts/uninstall.sh  (or kill PIDs in $PID_FILE)"
echo ""
ok "Port-forwards started"
echo ""
