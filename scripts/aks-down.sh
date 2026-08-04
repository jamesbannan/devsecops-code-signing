#!/usr/bin/env bash
# =============================================================================
# aks-down.sh — Tear down the dev/test AKS cluster + ACR.
# =============================================================================
# Steps:
#   1. Stop any running port-forwards (/tmp/devsecops-pf.pids)
#   2. Best-effort: helm uninstall the demo release
#   3. terraform destroy (in infra/aks/)
#   4. Remove chart/values-aks.local.yaml
#
# Set AUTO_APPROVE=true to skip the terraform destroy confirmation prompt.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra/aks"
CHART_DIR="$REPO_ROOT/chart"
VALUES_LOCAL="$CHART_DIR/values-aks.local.yaml"
RELEASE_NAME="${RELEASE_NAME:-devsecops-demo}"
NAMESPACE="${NAMESPACE:-pki}"

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

header() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
info()   { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()     { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
warn()   { printf "  ${YELLOW}[WARN]${NC} %s\n" "$1"; }
fail()   { printf "  ${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }
step()   { printf "\n${YELLOW}▶ %s${NC}\n" "$1"; }

header "DevSecOps Demo — AKS Teardown"

for bin in terraform; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin not found on PATH."
done

# -----------------------------------------------------------------------------
# Step 1: stop any running port-forwards (they point at a cluster we're deleting)
# -----------------------------------------------------------------------------
PID_FILE="/tmp/devsecops-pf.pids"
if [ -f "$PID_FILE" ]; then
  step "Stopping port-forwards"
  while IFS= read -r pid; do
    if kill "$pid" 2>/dev/null; then
      info "Killed port-forward PID $pid"
    fi
  done < "$PID_FILE"
  rm -f "$PID_FILE"
fi
rm -f /tmp/pf-*.log 2>/dev/null || true

# -----------------------------------------------------------------------------
# Step 2: best-effort helm uninstall (only if kubectl context is reachable)
# -----------------------------------------------------------------------------
if command -v helm >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
  if kubectl cluster-info >/dev/null 2>&1; then
    step "helm uninstall (best effort)"
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
      helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m || \
        warn "helm uninstall failed — continuing with terraform destroy"
    else
      info "Release $RELEASE_NAME not found in namespace $NAMESPACE — skipping"
    fi
  else
    info "Cluster not reachable — skipping helm uninstall"
  fi
fi

# -----------------------------------------------------------------------------
# Step 3: terraform destroy
# -----------------------------------------------------------------------------
[ -d "$INFRA_DIR" ] || fail "Terraform stack not found at $INFRA_DIR"

header "Destroying AKS + ACR via Terraform"
step "terraform destroy"
TF_DESTROY_ARGS=(-input=false)
if [ "${AUTO_APPROVE:-false}" = "true" ]; then
  TF_DESTROY_ARGS+=(-auto-approve)
fi
terraform -chdir="$INFRA_DIR" destroy "${TF_DESTROY_ARGS[@]}"

# -----------------------------------------------------------------------------
# Step 4: cleanup rendered values file
# -----------------------------------------------------------------------------
if [ -f "$VALUES_LOCAL" ]; then
  step "Removing $VALUES_LOCAL"
  rm -f "$VALUES_LOCAL"
  ok "Removed"
fi

header "Done"
info "Azure resources destroyed. Local kubeconfig entry for the AKS cluster is left in place."
info "Remove it manually if desired:  kubectl config delete-context <cluster>"
