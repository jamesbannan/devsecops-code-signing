#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Clean teardown of the DevSecOps demo environment
# =============================================================================
# 1. Kills port-forwards from /tmp/devsecops-pf.pids
# 2. Helm uninstall
# 3. Optionally deletes component namespaces (prompts user)
# 4. Optionally deletes the minikube cluster (prompts user)
# =============================================================================
set -uo pipefail

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

RELEASE_NAME="${RELEASE_NAME:-devsecops-demo}"
PID_FILE="/tmp/devsecops-pf.pids"

header() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
info()   { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()     { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }

header "DevSecOps Demo — Uninstall"

# =============================================================================
# Step 1: Kill port-forwards
# =============================================================================
header "Stopping port-forwards"
if [[ -f "$PID_FILE" ]]; then
  while IFS= read -r pid; do
    if kill "$pid" 2>/dev/null; then
      info "Killed port-forward PID $pid"
    fi
  done < "$PID_FILE"
  rm -f "$PID_FILE"
  ok "Port-forwards stopped"
else
  info "No PID file found at $PID_FILE — nothing to kill"
fi

# Clean up log files
rm -f /tmp/pf-*.log 2>/dev/null || true

# =============================================================================
# Step 2: Helm uninstall
# =============================================================================
header "Removing Helm release: $RELEASE_NAME"
if helm status "$RELEASE_NAME" &>/dev/null; then
  helm uninstall "$RELEASE_NAME" --namespace pki --wait
  ok "Helm release '$RELEASE_NAME' removed"
else
  info "Helm release '$RELEASE_NAME' not found — skipping"
fi

# =============================================================================
# Step 3: Optionally delete component namespaces
# =============================================================================
header "Namespace cleanup"
echo ""
printf "  Delete component namespaces? (pki, registry, workload, policy)\n"
printf "  ${YELLOW}This will delete all PersistentVolumeClaims and data.${NC}\n"
printf "  [y/N] "
read -r ans
if [[ "${ans,,}" == "y" ]]; then
  for ns in pki registry workload policy; do
    if kubectl get namespace "$ns" &>/dev/null; then
      kubectl delete namespace "$ns" --timeout=60s 2>/dev/null && \
        ok "Deleted namespace: $ns" || info "Namespace $ns may take time to delete"
    else
      info "Namespace $ns not found — skipping"
    fi
  done
  ok "Namespace deletion initiated"
else
  info "Skipping namespace deletion"
fi

# =============================================================================
# Step 4: Optionally delete minikube cluster
# =============================================================================
echo ""
printf "  Delete the minikube cluster?\n"
printf "  ${RED}WARNING: This is irreversible and will delete all cluster data.${NC}\n"
printf "  [y/N] "
read -r ans2
if [[ "${ans2,,}" == "y" ]]; then
  if command -v minikube &>/dev/null; then
    minikube delete
    ok "Minikube cluster deleted"
  else
    info "minikube not found — skipping"
  fi
else
  info "Skipping minikube deletion"
fi

echo ""
ok "Uninstall complete"
echo ""
