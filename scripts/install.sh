#!/usr/bin/env bash
# =============================================================================
# install.sh — Helm install wrapper for the DevSecOps demo environment
# =============================================================================
# 1. Pre-flight checks (binaries, minikube, OIDC issuer)
# 2. helm dependency update
# 3. helm upgrade --install (no --wait; manual readiness checks follow)
# 4. Wait for core Deployments/StatefulSets to become Ready
# 4. Launch port-forwards
# 5. Initialize cosign TUF root against local mirror
# 6. Print endpoint summary
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$SCRIPT_DIR/../chart"
RELEASE_NAME="${RELEASE_NAME:-devsecops-demo}"
VALUES_FILE="${VALUES_FILE:-}"
TIMEOUT="${HELM_TIMEOUT:-15m}"

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

header()  { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
info()    { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()      { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
fail()    { printf "  ${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }
step()    { printf "\n${YELLOW}▶ %s${NC}\n" "$1"; }

# Cluster auto-detection (sets CLUSTER_KIND, REGISTRY, CLUSTER_REGISTRY, etc.)
# shellcheck source=./_cluster-detect.sh
source "$SCRIPT_DIR/_cluster-detect.sh"

header "DevSecOps Demo — Install"

info "Cluster kind: $CLUSTER_KIND"
if [ "$CLUSTER_KIND" = "aks" ]; then
  info "ACR login server: ${ACR_LOGIN_SERVER:-<unknown>}"
fi

# =============================================================================
# Step 1: Pre-flight checks
# =============================================================================
header "Pre-flight checks"

# Required binaries
for bin in helm kubectl cosign step; do
  if command -v "$bin" &>/dev/null; then
    ok "$bin found: $(command -v "$bin")"
  else
    fail "$bin not found on PATH. See README.md for installation instructions."
  fi
done

# minikube / cluster check
info "Checking cluster connectivity ..."
if ! kubectl cluster-info &>/dev/null; then
  if [ "$CLUSTER_KIND" = "aks" ]; then
    fail "Cannot reach Kubernetes cluster. Run: bash scripts/aks-up.sh"
  else
    fail "Cannot reach Kubernetes cluster. Run: bash scripts/start-minikube.sh"
  fi
fi
ok "Cluster reachable"

# OIDC issuer check — critical for Fulcio keyless signing
info "Checking OIDC issuer ..."
ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || echo "")

case "$CLUSTER_KIND" in
  minikube|other)
    EXPECTED_ISSUER="https://kubernetes.default.svc"
    if [ "$ISSUER" != "$EXPECTED_ISSUER" ]; then
      printf "  ${RED}[ERROR]${NC} OIDC issuer is '%s'\n" "$ISSUER"
      echo "         Expected: $EXPECTED_ISSUER"
      echo ""
      echo "  Fix: restart minikube with the correct flags:"
      echo "    bash scripts/start-minikube.sh"
      echo ""
      echo "  The --extra-config=apiserver.service-account-issuer flag is mandatory"
      echo "  for Fulcio keyless signing. Without it, Kubernetes ServiceAccount JWTs"
      echo "  carry an unpredictable issuer URL that Fulcio cannot validate."
      exit 1
    fi
    ;;
  aks)
    # AKS exposes a public OIDC issuer URL (https://oidc.prod-aks.azure.com/<guid>/).
    # We accept whatever the cluster reports; values-aks.local.yaml must reference
    # the same URL so Fulcio trusts ServiceAccount tokens issued by this cluster.
    if [ -z "$ISSUER" ]; then
      fail "AKS cluster did not return an OIDC issuer URL. Re-run scripts/aks-up.sh."
    fi
    if [ -n "${AKS_OIDC_ISSUER_URL:-}" ] && [ "$ISSUER" != "$AKS_OIDC_ISSUER_URL" ]; then
      printf "  ${YELLOW}[WARN]${NC} Issuer mismatch:\n"
      printf "         Cluster reports: %s\n" "$ISSUER"
      printf "         Terraform output: %s\n" "$AKS_OIDC_ISSUER_URL"
    fi
    ;;
esac
ok "OIDC issuer: $ISSUER"

# =============================================================================
# Step 2: helm dependency update
# =============================================================================
header "Updating Helm dependencies"
step "helm dependency update chart/"
helm dependency update "$CHART_DIR"
ok "Dependencies updated"

# =============================================================================
# Step 3: helm upgrade --install
# =============================================================================
header "Installing Helm release: $RELEASE_NAME"

HELM_ARGS=(
  upgrade --install "$RELEASE_NAME" "$CHART_DIR"
  --namespace pki
  --create-namespace
  --timeout "$TIMEOUT"
)

if [ -z "$VALUES_FILE" ] && [ "$CLUSTER_KIND" = "aks" ]; then
  AUTO_VALUES="$CHART_DIR/values-aks.local.yaml"
  if [ -f "$AUTO_VALUES" ]; then
    VALUES_FILE="$AUTO_VALUES"
    info "Auto-selected AKS values file: $VALUES_FILE"
  else
    fail "On AKS but $AUTO_VALUES not found. Run: bash scripts/aks-up.sh"
  fi
fi

if [ -n "$VALUES_FILE" ]; then
  HELM_ARGS+=(-f "$VALUES_FILE")
  info "Using values file: $VALUES_FILE"
fi

step "helm ${HELM_ARGS[*]}"
info "Helm will install without --wait; a post-install readiness check follows."
info "Tail full detail in another terminal with: kubectl get pods -A -w"

# ---------------------------------------------------------------------------
# Background progress watcher
# ---------------------------------------------------------------------------
# Spawn a watcher that prints a one-line summary every 15s of pods that are
# not yet Ready, so the operator can see progress (or get an early hint when
# something is stuck in ImagePullBackOff / CrashLoopBackOff).
WATCH_NAMESPACES="pki registry workload policy fulcio-system rekor-system tuf-system trillian-system ctlog-system"

_watch_progress() {
  local tick=0
  while true; do
    tick=$((tick + 1))
    local elapsed=$((tick * 15))
    local not_ready
    not_ready=$(kubectl get pods -A --no-headers 2>/dev/null | \
      awk -v nslist="$WATCH_NAMESPACES" '
        BEGIN { split(nslist, a, " "); for (i in a) want[a[i]] = 1 }
        {
          ns=$1; name=$2; ready=$3; status=$4
          if (!(ns in want)) next
          split(ready, r, "/")
          if (r[1] != r[2] || status != "Running") {
            printf "    %s/%s  %s  %s\n", ns, name, status, ready
          }
        }')
    if [ -z "$not_ready" ]; then
      printf "  [watch +%ds] all watched pods Ready ...\n" "$elapsed"
    else
      local count
      count=$(printf "%s\n" "$not_ready" | wc -l | tr -d ' ')
      printf "  [watch +%ds] %s pod(s) not yet Ready:\n%s\n" "$elapsed" "$count" "$not_ready"
    fi
    sleep 15
  done
}

_watch_progress &
WATCH_PID=$!
trap 'kill "$WATCH_PID" 2>/dev/null || true' EXIT INT TERM

if ! helm "${HELM_ARGS[@]}"; then
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  trap - EXIT INT TERM
  printf "\n  ${RED}[ERROR]${NC} helm install failed\n"
  exit 1
fi

ok "Helm release submitted: $RELEASE_NAME"

# ---------------------------------------------------------------------------
# Wait for core Deployments / StatefulSets to become Ready
# ---------------------------------------------------------------------------
# We deliberately don't use helm --wait because demo workload Jobs
# (signing-job-sigstore, verification-job) are expected to fail until the
# demo image is built via build-and-push.sh. Instead, we wait only for the
# core infrastructure Deployments and StatefulSets.
info "Waiting for core Deployments and StatefulSets to become Ready ..."

DEPLOY_WAIT_LIST=(
  "trillian-system/deployment/trillian-mysql"
  "trillian-system/deployment/trillian-logserver"
  "trillian-system/deployment/trillian-logsigner"
  "fulcio-system/deployment/fulcio-server"
  "rekor-system/deployment/rekor-server"
  "ctlog-system/deployment/ctlog"
  "tuf-system/deployment/${RELEASE_NAME}-tuf-tuf"
  "pki/statefulset/${RELEASE_NAME}-stepca"
  "registry/deployment/registry"
  "policy/deployment/kyverno-admission-controller"
)

DEPLOY_TIMEOUT=600  # 10 minutes
DEPLOY_FAILED=0

for res in "${DEPLOY_WAIT_LIST[@]}"; do
  ns="${res%%/*}"
  kind_name="${res#*/}"
  printf "  Waiting for %s in %s ... " "$kind_name" "$ns"
  if kubectl rollout status "$kind_name" -n "$ns" --timeout="${DEPLOY_TIMEOUT}s" 2>/dev/null; then
    printf "${GREEN}Ready${NC}\n"
  else
    printf "${RED}FAILED${NC}\n"
    DEPLOY_FAILED=1
  fi
done

kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
trap - EXIT INT TERM

if [ "$DEPLOY_FAILED" -ne 0 ]; then
  printf "\n  ${RED}[ERROR]${NC} One or more core Deployments failed to become Ready.\n"
  printf "  Diagnose stuck pods with:\n"
  printf "    ${CYAN}kubectl get pods -A | grep -Ev 'Running|Completed'${NC}\n"
  printf "    ${CYAN}kubectl describe pod -n <ns> <pod>${NC}\n"
  exit 1
fi

ok "All core infrastructure is Ready"

# ---------------------------------------------------------------------------
# Apply Kyverno ClusterPolicy (require-image-signature)
# ---------------------------------------------------------------------------
# The ClusterPolicy is intentionally NOT installed by the initial helm release.
# Kyverno's admission webhook (devsecops-demo-kyverno-svc) needs ready endpoints
# before it can admit ClusterPolicy CRDs; on slower clusters (notably AKS cold
# starts) the post-install hook fires before those endpoints exist, producing
# "no endpoints available for service ...kyverno-svc". We deferred the policy
# behind .Values.workload.policy.installClusterPolicy; now that the admission
# controller deployment is Available, wait for the Service to have at least one
# endpoint and then enable the policy via a second helm upgrade.
header "Applying Kyverno ClusterPolicy"

KYVERNO_SVC="${RELEASE_NAME}-kyverno-svc"
info "Waiting for endpoints on policy/${KYVERNO_SVC} ..."
KYVERNO_ENDPOINTS_READY=0
for _ in $(seq 1 60); do
  ADDRS=$(kubectl get endpoints "$KYVERNO_SVC" -n policy \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  if [ -n "$ADDRS" ]; then
    KYVERNO_ENDPOINTS_READY=1
    break
  fi
  sleep 5
done
if [ "$KYVERNO_ENDPOINTS_READY" -ne 1 ]; then
  fail "Kyverno admission webhook endpoints never populated (policy/${KYVERNO_SVC})."
fi
ok "Kyverno admission webhook endpoints ready: $ADDRS"

step "helm upgrade --reuse-values --set workload.policy.installClusterPolicy=true"
HELM_POLICY_ARGS=(
  upgrade "$RELEASE_NAME" "$CHART_DIR"
  --namespace pki
  --reuse-values
  --set workload.policy.installClusterPolicy=true
  --timeout "$TIMEOUT"
)
if ! helm "${HELM_POLICY_ARGS[@]}"; then
  fail "Failed to apply Kyverno ClusterPolicy via helm upgrade."
fi
ok "ClusterPolicy require-image-signature applied"

# =============================================================================
# Step 4: Port-forwards
# =============================================================================
header "Starting port-forwards"
bash "$SCRIPT_DIR/port-forward.sh"

# =============================================================================
# Step 5: Initialize cosign TUF root
# =============================================================================
header "Initializing cosign TUF trust root"

info "Waiting for TUF service to be ready ..."
sleep 5

# Allow TUF to be reached; retry a few times
TUF_URL="http://localhost:30100"
for i in 1 2 3 4 5; do
  if curl -sf "$TUF_URL/root.json" -o /dev/null 2>/dev/null; then
    ok "TUF mirror reachable at $TUF_URL"
    break
  fi
  info "TUF not ready yet (attempt $i/5), waiting 10s ..."
  sleep 10
done

step "cosign initialize --mirror $TUF_URL --root $TUF_URL/root.json"
cosign initialize --mirror "$TUF_URL" --root "$TUF_URL/root.json" || {
  printf "  ${YELLOW}[WARN]${NC} cosign TUF initialization failed. Run manually:\n"
  printf "    cosign initialize --mirror %s --root %s/root.json\n" "$TUF_URL" "$TUF_URL"
}

# =============================================================================
# Step 6: Endpoint summary
# =============================================================================
header "Endpoint summary"
printf "\n"
printf "  %-20s %-40s %s\n" "Service" "Host URL" "In-cluster DNS"
printf "  %-20s %-40s %s\n" "-------" "--------" "--------------"
if [ "$CLUSTER_KIND" = "aks" ]; then
  printf "  %-20s %-40s %s\n" "Container Registry" "${ACR_LOGIN_SERVER:-<unknown>} (ACR)" "${ACR_LOGIN_SERVER:-<unknown>}"
  printf "  %-20s %-40s %s\n" "Registry mirror"   "localhost:30500" "registry.registry.svc:5000"
else
  printf "  %-20s %-40s %s\n" "Docker Registry" "localhost:30500" "registry.registry.svc:5000"
fi
printf "  %-20s %-40s %s\n" "Rekor" "http://localhost:30300" "rekor-server.rekor-system.svc:80"
printf "  %-20s %-40s %s\n" "Fulcio" "http://localhost:30200" "fulcio-server.fulcio-system.svc:80"
printf "  %-20s %-40s %s\n" "TUF mirror" "http://localhost:30100" "tuf-server.tuf-system.svc:80"
printf "  %-20s %-40s %s\n" "step-ca" "https://localhost:39000" "step-ca.pki.svc:9000"
printf "\n"

ok "Installation complete!"
echo ""
printf "  ${YELLOW}Next steps:${NC}\n"
printf "    1. Verify the stack:        ${CYAN}bash scripts/verify.sh${NC}\n"
printf "    2. Build & push demo image: ${CYAN}bash demos/demo-app/build-and-push.sh${NC}\n"
printf "       ${YELLOW}(required for demos 2, 3, 6; demo 4 builds its own; demos 1 & 5 don't need it)${NC}\n"
printf "    3. Run the demos:           ${CYAN}bash demos/demo1-before/run.sh${NC}\n"
printf "                                ${CYAN}bash demos/demo2-smallstep/run.sh${NC}\n"
printf "                                ${CYAN}bash demos/demo3-sigstore/run.sh${NC}\n"
printf "                                ${CYAN}bash demos/demo4-cicd/run.sh${NC}\n"
printf "                                ${CYAN}bash demos/demo5-verification/run.sh${NC}\n"
printf "                                ${CYAN}bash demos/demo6-audit/run.sh${NC}\n"
echo ""
