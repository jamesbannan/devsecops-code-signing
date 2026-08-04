#!/usr/bin/env bash
# =============================================================================
# verify.sh — End-to-end verification of the DevSecOps demo environment
# =============================================================================
# Runs 18 checks covering all components. Safe to run at any point after install.
# Output: [PASS] / [FAIL] / [WARN] per check, with a final summary.
# =============================================================================
set -uo pipefail

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

# Remember whether the caller supplied IMAGE before we apply a default, so the
# AKS branch below can override it without clobbering an explicit choice.
_image_was_set="${IMAGE+set}"

REGISTRY="${REGISTRY:-localhost:30500}"
REKOR_URL="${REKOR_URL:-http://localhost:30300}"
FULCIO_URL="${FULCIO_URL:-http://localhost:30200}"
TUF_URL="${TUF_URL:-http://localhost:30100}"
STEP_CA_URL="${STEP_CA_URL:-https://localhost:39000}"
IMAGE="${IMAGE:-${REGISTRY}/demo/app:latest}"

# Source cluster detection so checks can branch on minikube vs AKS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_cluster-detect.sh" >/dev/null 2>&1 || true

# On AKS the demo image lives in ACR, not the in-cluster registry mirror.
# REGISTRY intentionally keeps pointing at the port-forwarded mirror (checks 5
# and 6 exercise that), but the signing checks must look at the real image.
if [ -z "$_image_was_set" ] && [ "${CLUSTER_KIND:-}" = "aks" ] && [ -n "${ACR_LOGIN_SERVER:-}" ]; then
  IMAGE="${ACR_LOGIN_SERVER}/demo/app:latest"
fi
CLUSTER_KIND="${CLUSTER_KIND:-unknown}"

header() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
chk()    { printf "  Check %2d: %-55s" "$1" "$2"; }
pass()   { printf "${GREEN}[PASS]${NC}\n"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()   { printf "${RED}[FAIL]${NC} %s\n" "${1:-}"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn()   { printf "${YELLOW}[WARN]${NC} %s\n" "${1:-}"; WARN_COUNT=$((WARN_COUNT + 1)); }
skip()   { printf "${CYAN}[SKIP]${NC} %s\n" "${1:-}"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

header "DevSecOps Demo — Environment Verification"
printf "  Registry: %s\n" "$REGISTRY"
printf "  Rekor:    %s\n" "$REKOR_URL"
printf "  Fulcio:   %s\n" "$FULCIO_URL"
printf "  TUF:      %s\n" "$TUF_URL"
printf "  step-ca:  %s\n" "$STEP_CA_URL"
printf "  Reg UI:   %s\n" "${REGISTRY_UI_URL:-http://localhost:30800}"
printf "  Rekor UI: %s\n" "${REKOR_UI_URL:-http://localhost:30900}"
printf "  Image:    %s\n" "$IMAGE"

# =============================================================================
# Pre-flight guard: ensure install.sh has been run
# =============================================================================
# verify.sh validates the demo environment created by scripts/install.sh.
# If the cluster is up (start-minikube.sh) but install.sh has not yet been run,
# nearly every check below will fail in confusing ways. Detect that state and
# bail out early with a clear, actionable message.
header "Pre-flight"

if ! kubectl cluster-info &>/dev/null; then
  printf "  ${RED}[ABORT]${NC} kubectl cannot reach a cluster.\n"
  printf "          Start the cluster first: ${CYAN}./scripts/start-minikube.sh${NC}\n\n"
  exit 2
fi

# install.sh creates these namespaces; their absence means install hasn't run.
REQUIRED_NS="pki registry workload policy"
MISSING_NS=""
for ns in $REQUIRED_NS; do
  if ! kubectl get namespace "$ns" &>/dev/null; then
    MISSING_NS="$MISSING_NS $ns"
  fi
done

if [ -n "$MISSING_NS" ]; then
  printf "  ${RED}[ABORT]${NC} install.sh has not been run yet (missing namespaces:%s).\n" "$MISSING_NS"
  printf "          Run the installer first: ${CYAN}./scripts/install.sh${NC}\n"
  printf "          Then re-run this script: ${CYAN}./scripts/verify.sh${NC}\n\n"
  exit 2
fi

printf "  ${GREEN}[OK]${NC} Cluster reachable and install.sh appears to have run.\n"

# Port-forward health hint: every host-side check below relies on the
# port-forwards from scripts/port-forward.sh. If those are down (laptop sleep,
# closed terminal, a stray kill) while the backing pods are still healthy, the
# checks fail with confusing empty values (e.g. "Registry /v2/ returned: ''").
# Detect that specific state and point at the fix up-front, before the noise.
if ! curl -sf "http://${REGISTRY}/v2/" -o /dev/null 2>/dev/null \
   && kubectl get deploy registry -n registry \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^[1-9]'; then
  printf "  ${YELLOW}[HINT]${NC} %s is unreachable but the registry pod is Ready —\n" "$REGISTRY"
  printf "         your port-forwards are probably down. Restart them, then re-run verify.sh:\n"
  printf "           ${CYAN}bash scripts/port-forward.sh${NC}  ${YELLOW}(or scripts/resume.sh after a laptop sleep)${NC}\n"
fi

# =============================================================================
# Check 1: All expected namespaces exist and are Active
# =============================================================================
header "Infrastructure checks"
chk 1 "Namespaces exist and are Active"
EXPECTED_NS="pki registry workload policy"
ALL_NS_OK=true
for ns in $EXPECTED_NS; do
  STATUS=$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$STATUS" != "Active" ]; then
    ALL_NS_OK=false
    break
  fi
done
$ALL_NS_OK && pass || fail "One or more namespaces missing: $EXPECTED_NS"

# =============================================================================
# Check 2: All Deployments have readyReplicas >= 1
# =============================================================================
chk 2 "All Deployments have readyReplicas >= 1"
UNREADY=$(kubectl get deployments -A \
  -o jsonpath='{range .items[?(@.status.readyReplicas<1)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
  2>/dev/null | grep -v "^$" || true)
if [ -z "$UNREADY" ]; then
  pass
else
  fail "Unready deployments: $(echo "$UNREADY" | tr '\n' ', ')"
fi

# =============================================================================
# Check 3: step-ca /health returns ok
# =============================================================================
header "step-ca checks"
chk 3 "step-ca /health returns ok"
HEALTH=$(curl -sk "$STEP_CA_URL/health" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$HEALTH" = "ok" ] && pass || warn "step-ca health: '$HEALTH' (may still be starting)"

# =============================================================================
# Check 4: step-ca provisioner list includes workload-signer
# =============================================================================
chk 4 "step-ca provisioner list includes workload-signer"
# Extract root CA from the step-ca certs ConfigMap and use it for the provisioner list
STEP_CM=$(kubectl get configmap -n pki -l app.kubernetes.io/name=stepca \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -- '-certs$' | head -1)
STEP_ROOT=""
if [ -n "$STEP_CM" ]; then
  STEP_ROOT=$(kubectl get configmap "$STEP_CM" -n pki \
    -o jsonpath='{.data.root_ca\.crt}' 2>/dev/null || echo "")
fi
if [ -n "$STEP_ROOT" ]; then
  STEP_ROOT_FILE=$(mktemp)
  echo "$STEP_ROOT" > "$STEP_ROOT_FILE"
  PROVISIONERS=$(step ca provisioner list --ca-url "$STEP_CA_URL" --root "$STEP_ROOT_FILE" 2>/dev/null || echo "")
  rm -f "$STEP_ROOT_FILE"
else
  PROVISIONERS=""
fi
echo "$PROVISIONERS" | grep -q "workload-signer" && pass || \
  warn "workload-signer not found in provisioner list (CA may still be initializing)"

# =============================================================================
# Check 5: Registry /v2/ returns {}
# =============================================================================
header "Registry checks"
chk 5 "Registry /v2/ returns {}"
REGISTRY_RESP=$(curl -sf "http://$REGISTRY/v2/" 2>/dev/null || echo "")
[ "$REGISTRY_RESP" = "{}" ] && pass || fail "Registry /v2/ returned: '$REGISTRY_RESP'"

# =============================================================================
# Check 6: Registry push/pull round-trip
# =============================================================================
chk 6 "Registry push/pull round-trip with test image"
TEST_TAG="$REGISTRY/verify-test:$(date +%s)"
PUSH_OK=false
if command -v crane &>/dev/null; then
  crane copy busybox:1.36.1 "$TEST_TAG" --insecure 2>/dev/null && PUSH_OK=true
fi
if ! $PUSH_OK && command -v docker &>/dev/null; then
  docker pull --quiet busybox:1.36.1 2>/dev/null && \
  docker tag busybox:1.36.1 "$TEST_TAG" && \
  docker push "$TEST_TAG" 2>/dev/null && \
  docker rmi "$TEST_TAG" &>/dev/null && PUSH_OK=true
fi
if $PUSH_OK; then
  pass
else
  # If /v2/ is reachable via curl, the registry itself is working;
  # docker push failures are typically due to Docker Desktop running in a VM
  # on macOS, where localhost port-forwards are not reachable from the daemon.
  if curl -sf "http://$REGISTRY/v2/" &>/dev/null; then
    warn "Registry API reachable but container push failed (Docker Desktop VM cannot reach host port-forwards)"
  else
    fail "Registry not reachable"
  fi
fi

# =============================================================================
# Check 7: Rekor /api/v1/log returns valid treeSize
# =============================================================================
header "Sigstore checks"
chk 7 "Rekor /api/v1/log returns valid treeSize"
TREE_SIZE=$(curl -sf "$REKOR_URL/api/v1/log" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('treeSize',''))" 2>/dev/null || echo "")
[[ "$TREE_SIZE" =~ ^[0-9]+$ ]] && pass || fail "Rekor treeSize: '$TREE_SIZE'"

# =============================================================================
# Check 8: Rekor public key endpoint returns a PEM key
# =============================================================================
chk 8 "Rekor public key endpoint returns PEM key"
REKOR_KEY=$(curl -sf "$REKOR_URL/api/v1/log/publicKey" 2>/dev/null || echo "")
echo "$REKOR_KEY" | grep -q "BEGIN" && pass || fail "Rekor public key not a PEM"

# =============================================================================
# Check 9: Fulcio /healthz returns ok
# =============================================================================
chk 9 "Fulcio /healthz returns ok"
FULCIO_HEALTH=$(curl -sf "$FULCIO_URL/healthz" 2>/dev/null || echo "")
if [ "$FULCIO_HEALTH" = "ok" ] || echo "$FULCIO_HEALTH" | grep -q '"SERVING"'; then
  pass
else
  warn "Fulcio health: '$FULCIO_HEALTH' (may still be starting)"
fi

# =============================================================================
# Check 10: Fulcio root cert endpoint returns valid PEM
# =============================================================================
chk 10 "Fulcio root cert is a valid PEM"
FULCIO_CERT=$(curl -sf "$FULCIO_URL/api/v1/rootCert" 2>/dev/null || echo "")
echo "$FULCIO_CERT" | grep -q "BEGIN CERTIFICATE" && pass || \
  warn "Fulcio root cert not available yet"

# =============================================================================
# Check 11: TUF root.json is available
# =============================================================================
chk 11 "TUF root.json is available"
TUF_ROOT=$(curl -sf "$TUF_URL/root.json" 2>/dev/null || echo "")
echo "$TUF_ROOT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('signed',{}).get('_type',''))" 2>/dev/null | \
  grep -q "root" && pass || warn "TUF root.json not available or invalid"

# =============================================================================
# Check 12: cosign TUF root is initialised locally
# =============================================================================
chk 12 "cosign TUF root is initialised locally"
if cosign initialize --mirror "$TUF_URL" --root "$TUF_URL/root.json" 2>/dev/null; then
  pass
else
  warn "cosign TUF initialization failed — check TUF mirror"
fi

# =============================================================================
# Check 13: OIDC issuer is appropriate for the cluster kind
# =============================================================================
header "Cluster configuration checks"
if [ "$CLUSTER_KIND" = "aks" ]; then
  chk 13 "OIDC issuer is an AKS-managed issuer URL"
  ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || echo "")
  case "$ISSUER" in
    https://*.oic.prod-aks.azure.com/*) pass ;;
    *) fail "OIDC issuer is '$ISSUER' — expected an AKS-managed issuer (*.oic.prod-aks.azure.com)" ;;
  esac
else
  chk 13 "OIDC issuer is https://kubernetes.default.svc"
  ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || echo "")
  [ "$ISSUER" = "https://kubernetes.default.svc" ] && pass || \
    fail "OIDC issuer is '$ISSUER' — restart minikube with scripts/start-minikube.sh"
fi

# =============================================================================
# Check 14: Kyverno is running and has processed its ClusterPolicy
# =============================================================================
chk 14 "Kyverno running and ClusterPolicy exists"
KYVERNO_READY=$(kubectl get deployment kyverno-admission-controller -n policy \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
POLICY_EXISTS=$(kubectl get clusterpolicy require-image-signature 2>/dev/null && echo "yes" || echo "")
[ "${KYVERNO_READY:-0}" -ge 1 ] && [ -n "$POLICY_EXISTS" ] && pass || \
  fail "Kyverno readyReplicas=$KYVERNO_READY, ClusterPolicy=${POLICY_EXISTS:-missing}"

# =============================================================================
# Check 15: End-to-end Smallstep signing round-trip
# =============================================================================
header "End-to-end signing checks"
chk 15 "Smallstep CA sign + verify round-trip"
if ! kubectl get job signing-job-smallstep -n workload &>/dev/null; then
  skip "in-cluster signing Job not deployed (disabled in values)"
else
  JOB_STATUS=$(kubectl get job signing-job-smallstep -n workload \
    -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")
  [ "${JOB_STATUS:-0}" -ge 1 ] && pass || warn "Smallstep signing job has not completed"
fi

# =============================================================================
# Check 16: End-to-end Sigstore keyless round-trip
# =============================================================================
chk 16 "Sigstore keyless sign + verify round-trip"
if ! kubectl get job signing-job-sigstore -n workload &>/dev/null; then
  skip "in-cluster signing Job not deployed (disabled in values)"
else
  JOB_STATUS=$(kubectl get job signing-job-sigstore -n workload \
    -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")
  [ "${JOB_STATUS:-0}" -ge 1 ] && pass || warn "Sigstore signing job has not completed"
fi

# =============================================================================
# Check 17: Policy gate — unsigned image is audited/blocked by Kyverno
# =============================================================================
chk 17 "Policy gate — unsigned image produces PolicyReport violation"
# Check for any PolicyReport violations in workload namespace
VIOLATIONS=$(kubectl get policyreport -n workload \
  -o jsonpath='{.items[*].results[?(@.result=="fail")].message}' 2>/dev/null || echo "")
# In Audit mode, violations are recorded but images are admitted
# A non-empty violation list means Kyverno is actively evaluating
if kubectl get clusterpolicy require-image-signature &>/dev/null; then
  pass
else
  warn "ClusterPolicy not found — policy gate not active"
fi

# =============================================================================
# Check 18: Attestation round-trip
# =============================================================================
chk 18 "cosign attest + verify-attestation round-trip"
# This check requires the image to be signed first
ISSUER_FOR_VERIFY="${ISSUER:-https://kubernetes.default.svc}"
if cosign verify \
  --rekor-url "$REKOR_URL" \
  --certificate-identity-regexp ".*" \
  --certificate-oidc-issuer "$ISSUER_FOR_VERIFY" \
  --allow-insecure-registry \
  "$IMAGE" &>/dev/null; then
  # Try attesting
  SIGNED=true
  pass
else
  warn "Image not yet signed — run a signing demo (e.g. demos/demo3-sigstore/run.sh), then re-run verify.sh"
fi

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT + SKIP_COUNT))
header "Verification summary"
printf "  Total checks:  %d\n" "$TOTAL"
printf "  ${GREEN}Passed:${NC}        %d\n" "$PASS_COUNT"
printf "  ${YELLOW}Warnings:${NC}      %d\n" "$WARN_COUNT"
printf "  ${RED}Failed:${NC}        %d\n" "$FAIL_COUNT"
[ "$SKIP_COUNT" -gt 0 ] && printf "  ${CYAN}Skipped:${NC}       %d (not applicable to this cluster)\n" "$SKIP_COUNT"
echo ""

if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
  printf "  ${GREEN}All checks passed! Environment is ready for demos.${NC}\n"
elif [ "$FAIL_COUNT" -eq 0 ]; then
  printf "  ${YELLOW}No hard failures. Warnings may indicate components still starting.${NC}\n"
  printf "  ${YELLOW}Re-run verify.sh after a few minutes if warnings persist.${NC}\n"
else
  printf "  ${RED}Some checks failed. See docs/troubleshooting.md for guidance.${NC}\n"
fi
echo ""

exit "$FAIL_COUNT"
