#!/usr/bin/env bash
# =============================================================================
# start-minikube.sh — Bootstrap the local minikube cluster for the demo
# =============================================================================
# Starts minikube with all flags required for the DevSecOps code-signing demo:
#   - Podman driver + containerd runtime
#   - Insecure registry at localhost:30500 (Docker Registry v2 NodePort)
#   - OIDC issuer set to https://kubernetes.default.svc (required for Fulcio)
#
# Idempotent: if minikube is already running with the correct profile, skips start.
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PROFILE="${MINIKUBE_PROFILE:-minikube}"

header() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
info()   { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()     { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
fail()   { printf "  ${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

header "DevSecOps Demo — Minikube Bootstrap"

# --- Pre-flight: check minikube binary ---
if ! command -v minikube &>/dev/null; then
  fail "minikube not found on PATH. Install from https://minikube.sigs.k8s.io/docs/start/"
fi

if ! command -v podman &>/dev/null; then
  fail "podman not found on PATH. Install Podman Desktop from https://podman-desktop.io/"
fi

info "Using minikube profile: $PROFILE"

# --- Check if cluster is already running ---
CURRENT_STATUS=$(minikube status --profile "$PROFILE" -o json 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Host',''))" 2>/dev/null || echo "")

if [ "$CURRENT_STATUS" = "Running" ]; then
  ok "Minikube is already running."

  # Verify the OIDC issuer is correctly configured
  info "Checking OIDC issuer configuration ..."
  ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || echo "")

  if [ "$ISSUER" = "https://kubernetes.default.svc" ]; then
    ok "OIDC issuer: $ISSUER"
    echo ""
    ok "Cluster is ready. Run: bash scripts/install.sh"
    exit 0
  else
    printf "  ${YELLOW}[WARN]${NC} OIDC issuer is '%s' (expected https://kubernetes.default.svc)\n" "$ISSUER"
    info "Stopping cluster to apply correct OIDC configuration ..."
    minikube stop --profile "$PROFILE"
  fi
fi

# --- Start minikube with required configuration ---
header "Starting minikube cluster"
info "Driver:            podman"
info "Container runtime: containerd"
info "CNI:               bridge"
info "CPUs:              4"
info "Memory:            8192 MiB"
info "Kubernetes:        v1.35.1"
info "Insecure registry: localhost:30500"
info "OIDC issuer:       https://kubernetes.default.svc"
echo ""

minikube start \
  --profile "$PROFILE" \
  --driver=podman \
  --container-runtime=containerd \
  --cni=bridge \
  --cpus=4 \
  --memory=8192 \
  --kubernetes-version=v1.35.1 \
  --insecure-registry="localhost:30500" \
  --extra-config=apiserver.service-account-issuer=https://kubernetes.default.svc \
  --extra-config=apiserver.api-audiences=https://kubernetes.default.svc

# --- Post-start verification ---
header "Verifying cluster configuration"

info "Checking OIDC issuer ..."
MAX_WAIT=60
WAITED=0
while true; do
  ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || echo "")
  if [ "$ISSUER" = "https://kubernetes.default.svc" ]; then
    ok "OIDC issuer: $ISSUER"
    break
  fi
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    fail "OIDC issuer did not become https://kubernetes.default.svc after ${MAX_WAIT}s. Got: '$ISSUER'"
  fi
  sleep 5
  WAITED=$((WAITED + 5))
  info "Waiting for API server to be ready ... (${WAITED}s)"
done

info "Checking node status (this can take a few minutes on first boot while the CNI initialises) ..."
if ! kubectl wait --for=condition=Ready node --all --timeout=300s; then
  printf "  ${RED}[ERROR]${NC} Node did not become Ready within 300s. Diagnostics:\n\n"
  echo "--- kubectl get nodes -o wide ---"
  kubectl get nodes -o wide || true
  echo ""
  echo "--- kubectl describe node ---"
  kubectl describe node || true
  echo ""
  echo "--- kubectl get pods -A ---"
  kubectl get pods -A || true
  echo ""
  echo "--- kubelet status (inside node) ---"
  minikube ssh --profile "$PROFILE" -- 'sudo systemctl status kubelet --no-pager | tail -n 40' || true
  fail "Node never reached Ready. See diagnostics above."
fi
ok "All nodes ready"

echo ""
ok "Minikube cluster is ready!"
echo ""
printf "  Next step: ${CYAN}bash scripts/install.sh${NC}\n"
echo ""
