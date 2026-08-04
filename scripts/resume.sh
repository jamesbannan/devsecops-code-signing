#!/usr/bin/env bash
# =============================================================================
# resume.sh — Restore the demo environment after the laptop has woken from sleep
# =============================================================================
# When the demo laptop sleeps, several things break:
#
#   * `kubectl port-forward` processes survive but their TCP connections are
#     dead (the local sockets accept connections, then immediately RST).
#   * Stale PIDs may exist that no longer correspond to kubectl processes.
#   * The Azure CLI / AKS token may have expired (~24h validity).
#   * minikube's VM clock may have drifted.
#
# This script makes the environment safe to demo again without re-running
# `install.sh` or recreating the cluster:
#
#   1. Detect the cluster (minikube or AKS).
#   2. Verify the Kubernetes API is reachable; for AKS, re-run `az aks
#      get-credentials` if the token is stale.
#   3. Kill all surviving `kubectl port-forward` processes (PID file + a
#      best-effort scan), so we get a clean slate.
#   4. Re-run `scripts/port-forward.sh`.
#   5. Probe each forwarded endpoint with curl and retry once if anything
#      is still broken.
#
# Usage:
#   bash scripts/resume.sh
#   FORCE_AKS_REAUTH=1 bash scripts/resume.sh    # also runs az login
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

header() { printf "\n${CYAN}${BOLD}=== %s ===${NC}\n" "$1"; }
info()   { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()     { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
warn()   { printf "  ${YELLOW}[WARN]${NC} %s\n" "$1"; }
fail()   { printf "  ${RED}[FAIL]${NC} %s\n" "$1"; }

PID_FILE="/tmp/devsecops-pf.pids"
FORCE_AKS_REAUTH="${FORCE_AKS_REAUTH:-0}"

# Endpoints we expect to be reachable after port-forwards are up.
# Format: "label|url|expected-substring-or-status-code"
ENDPOINTS=(
  "Registry|http://localhost:30500/v2/|200"
  "Rekor|http://localhost:30300/api/v1/log|200"
  "Fulcio|http://localhost:30200/|404"
  "TUF mirror|http://localhost:30100/timestamp.json|200"
  "step-ca|https://localhost:39000/health|200"
  "Registry UI|http://localhost:30800/|200"
  "Rekor Search UI|http://localhost:30900/|200"
)

# -----------------------------------------------------------------------------
# 1. Cluster detection + Kubernetes reachability
# -----------------------------------------------------------------------------
header "Detecting cluster"

# shellcheck source=_cluster-detect.sh
source "$SCRIPT_DIR/_cluster-detect.sh"

info "Cluster kind: ${CLUSTER_KIND:-unknown}"
info "Context:      $(kubectl config current-context 2>/dev/null || echo '<none>')"

if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  warn "Kubernetes API not reachable on the current context."
  if [ "$CLUSTER_KIND" = "aks" ]; then
    info "Re-fetching AKS credentials…"
    if [ "$FORCE_AKS_REAUTH" = "1" ]; then
      az login --only-show-errors >/dev/null || { fail "az login failed"; exit 1; }
    fi
    # Pick up the cluster name/RG from terraform output (best effort)
    AKS_NAME="$(cd "$REPO_ROOT/infra/aks" 2>/dev/null && terraform output -raw aks_cluster_name 2>/dev/null || echo "")"
    AKS_RG="$(cd "$REPO_ROOT/infra/aks" 2>/dev/null && terraform output -raw resource_group_name 2>/dev/null || echo "")"
    if [ -n "$AKS_NAME" ] && [ -n "$AKS_RG" ]; then
      az aks get-credentials -g "$AKS_RG" -n "$AKS_NAME" --overwrite-existing --only-show-errors \
        || { fail "az aks get-credentials failed"; exit 1; }
      ok "Refreshed kubeconfig for AKS cluster $AKS_NAME"
    else
      fail "Couldn't read terraform outputs — re-run \`az aks get-credentials\` manually."
      exit 1
    fi
  elif [ "$CLUSTER_KIND" = "minikube" ]; then
    info "Checking minikube status…"
    if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
      info "minikube is not running — starting it (this may take ~1 min)…"
      minikube start || { fail "minikube start failed"; exit 1; }
    fi
  fi

  if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    fail "Still cannot reach the Kubernetes API. Investigate manually."
    exit 1
  fi
fi
ok "Kubernetes API reachable"

# -----------------------------------------------------------------------------
# 2. Kill all surviving kubectl port-forward processes
# -----------------------------------------------------------------------------
header "Cleaning up stale port-forwards"

KILLED=0

# 2a. PIDs recorded by port-forward.sh
if [ -f "$PID_FILE" ]; then
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null && KILLED=$((KILLED + 1)) || true
      info "Killed recorded PID $pid"
    fi
  done < "$PID_FILE"
  rm -f "$PID_FILE"
fi

# 2b. Best-effort scan: any leftover `kubectl port-forward` we don't know about.
# Uses ps + grep so we don't depend on pgrep (not present on minimal images).
# Filter to our well-known local ports to avoid clobbering unrelated forwards.
WELL_KNOWN_PORTS="30500 30300 30200 30100 39000 30800 30900"
while IFS= read -r line; do
  pid=$(awk '{print $1}' <<<"$line")
  [ -z "$pid" ] && continue
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null && KILLED=$((KILLED + 1)) || true
    info "Killed orphan kubectl port-forward PID $pid"
  fi
done < <(ps -eo pid,command 2>/dev/null \
  | grep -E "kubectl[[:space:]]+.*port-forward" \
  | grep -vE "grep|resume\.sh" \
  | grep -E "$(echo $WELL_KNOWN_PORTS | tr ' ' '|')" || true)

if [ "$KILLED" -eq 0 ]; then
  info "No stale port-forwards found."
else
  ok "Killed $KILLED stale port-forward process(es)"
fi

# -----------------------------------------------------------------------------
# 3. Restart port-forwards
# -----------------------------------------------------------------------------
header "Restarting port-forwards"
bash "$SCRIPT_DIR/port-forward.sh"

# -----------------------------------------------------------------------------
# 4. Probe each endpoint to confirm it actually answers
# -----------------------------------------------------------------------------
header "Verifying endpoints"

probe() {
  local label="$1" url="$2" expected="$3"
  local extra=""
  case "$url" in https://*) extra="-k" ;; esac

  # Give the port-forward up to ~5s to become reachable.
  local code=""
  for _ in 1 2 3 4 5; do
    code=$(curl $extra -s -o /dev/null -w "%{http_code}" --max-time 2 "$url" 2>/dev/null || echo "000")
    if [ "$code" = "$expected" ] || { [ "$expected" = "200" ] && [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 400 ] 2>/dev/null; }; then
      ok "$label → $url  ($code)"
      return 0
    fi
    sleep 1
  done
  warn "$label → $url  (got $code, expected $expected)"
  return 1
}

FAILED_LABELS=()
for entry in "${ENDPOINTS[@]}"; do
  IFS='|' read -r label url expected <<<"$entry"
  if ! probe "$label" "$url" "$expected"; then
    FAILED_LABELS+=("$label")
  fi
done

# -----------------------------------------------------------------------------
# 5. Retry once if anything failed
# -----------------------------------------------------------------------------
if [ "${#FAILED_LABELS[@]}" -gt 0 ]; then
  header "Retrying failed endpoints"
  warn "Failed first time: ${FAILED_LABELS[*]}"
  info "Restarting port-forwards once more and re-probing…"
  bash "$SCRIPT_DIR/port-forward.sh"
  sleep 3

  STILL_FAILED=()
  for entry in "${ENDPOINTS[@]}"; do
    IFS='|' read -r label url expected <<<"$entry"
    case " ${FAILED_LABELS[*]} " in *" $label "*)
      probe "$label" "$url" "$expected" || STILL_FAILED+=("$label")
      ;;
    esac
  done

  if [ "${#STILL_FAILED[@]}" -gt 0 ]; then
    fail "Endpoints still not reachable: ${STILL_FAILED[*]}"
    fail "Check pod health:  kubectl get pods -A | grep -Ev 'Running|Completed'"
    fail "Check pf logs:     ls -lt /tmp/pf-*.log"
    exit 1
  fi
fi

echo ""
ok "Demo environment resumed — port-forwards healthy."
echo ""
info "Run a demo:        bash demos/demo3-sigstore/run.sh"
info "Re-verify stack:   bash scripts/verify.sh"
echo ""
