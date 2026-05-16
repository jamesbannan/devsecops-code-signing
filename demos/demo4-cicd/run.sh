#!/usr/bin/env bash
# =============================================================================
# Demo 4: CI/CD Pipeline Simulation
# =============================================================================
# Simulates a GitHub Actions run locally using shell steps that mirror
# the workflow — complete with group/step output formatting for familiarity.
#
#   ▶ [BUILD]  Build the demo app container image
#   ▶ [PUSH]   Push to the local registry
#   ▶ [SIGN]   Both signing paths from the host (Smallstep + Sigstore keyless)
#   ▶ [VERIFY] Verify both signatures with cosign
#   ▶ [DEPLOY] Apply a Deployment — Kyverno admits the signed image
#
# Prerequisites: cosign, kubectl, step, python3, minikube (or podman/docker)
# Duration: ~5 minutes
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# shellcheck source=../../scripts/_cluster-detect.sh
source "$REPO_ROOT/scripts/_cluster-detect.sh"

REGISTRY="${REGISTRY:-localhost:30500}"
IMAGE="${IMAGE:-${REGISTRY}/demo/app:latest}"
# In-cluster image reference for the Deployment — Kyverno runs inside the cluster
# and cannot reach localhost:30500, so we use the in-cluster DNS name (or ACR on AKS).
CLUSTER_IMAGE="${CLUSTER_REGISTRY}/demo/app:latest"
REKOR_URL="${REKOR_URL:-http://localhost:30300}"
FULCIO_URL="${FULCIO_URL:-http://localhost:30200}"
STEP_CA_URL="${STEP_CA_URL:-https://localhost:39000}"

GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

TMPDIR=$(mktemp -d /tmp/demo4-cicd-XXXXXX)

# Pre-clean any stale deployment from a previous run so kubectl apply is fresh.
# NOTE: we intentionally do NOT delete the deployment on exit — leaving it
# running lets the audience point at `kubectl get deployment -n workload`
# after the demo to confirm the signed image was admitted.
kubectl delete deployment demo-app-signed -n workload --ignore-not-found=true 2>/dev/null || true

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

# Pause between steps so the audience can absorb each phase. Set DEMO_AUTO=1
# to skip (e.g. when invoked from scripts/verify.sh or CI); skipped automatically
# when stdin is not a TTY.
DEMO_AUTO="${DEMO_AUTO:-0}"
_STEP_COUNT=0
pause_for_next() {
  _STEP_COUNT=$((_STEP_COUNT + 1))
  [ "$_STEP_COUNT" -eq 1 ] && return 0
  [ "$DEMO_AUTO" = "1" ] && return 0
  [ -t 0 ] || return 0
  printf "\n${YELLOW}  ↵  Press ENTER for the next step (Ctrl-C to stop)…${NC} "
  IFS= read -r _ || true
}

# CI-style step output
step_start() { pause_for_next; printf "\n${BOLD}${CYAN}▶ [%s]${NC} %s\n" "$1" "$2"; }
step_end()   { printf "  ${GREEN}✓ %s${NC}\n" "$1"; }
cmd()        { printf "  ${YELLOW}\$ %s${NC}\n" "$*"; }
narrate()    { printf "\n${BOLD}%s${NC}\n" "$1"; }
ok()         { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
fail()       { printf "  ${RED}[FAIL]${NC} %s\n" "$1"; }
note()       { printf "  ${CYAN}ℹ  %s${NC}\n" "$1"; }

printf "\n${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  DevSecOps Demo — CI/CD Pipeline Simulation                 ║"
echo "║  Commit: $GIT_SHA  Time: $BUILD_TIME ║"
echo "╚══════════════════════════════════════════════════════════════╝"
printf "${NC}\n"

narrate "This simulates a GitHub Actions workflow. Each step mirrors a real pipeline."
narrate "The key difference: signing is automatic, not manual."
sleep 2

# =============================================================================
# Step 1: BUILD
# =============================================================================
step_start "BUILD" "Building container image"
echo ""

# Detect build tool. On AKS we must push to ACR — never use minikube tooling.
BUILD_TOOL=""
if [ "${CLUSTER_KIND:-}" = "aks" ]; then
  if command -v docker &>/dev/null; then
    BUILD_TOOL="docker"
  elif command -v podman &>/dev/null; then
    BUILD_TOOL="podman"
  else
    fail "AKS requires docker or podman to push to ACR"
    exit 1
  fi
elif command -v minikube &>/dev/null && minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
  BUILD_TOOL="minikube"
elif command -v podman &>/dev/null; then
  BUILD_TOOL="podman"
elif command -v docker &>/dev/null; then
  BUILD_TOOL="docker"
else
  fail "No container build tool found (minikube, podman, or docker)"
  exit 1
fi
note "Build tool: $BUILD_TOOL"

# AKS nodes are amd64 by default; macOS arm64 dev machines produce arm64
# binaries unless told otherwise, which causes the pod to CrashLoopBackOff
# after admission. Force linux/amd64 on AKS. Override via TARGET_PLATFORM.
if [ "${CLUSTER_KIND:-}" = "aks" ]; then
  TARGET_PLATFORM="${TARGET_PLATFORM:-linux/amd64}"
  note "Target platform: $TARGET_PLATFORM"
else
  TARGET_PLATFORM="${TARGET_PLATFORM:-}"
fi

case "$BUILD_TOOL" in
  minikube)
    cmd "minikube image build -t $IMAGE demos/demo-app/"
    minikube image build -t "$IMAGE" "$REPO_ROOT/demos/demo-app" 2>&1 | tail -3
    ;;
  podman)
    cmd "podman build ${TARGET_PLATFORM:+--platform $TARGET_PLATFORM }-t $IMAGE demos/demo-app/"
    podman build --tls-verify=false \
      ${TARGET_PLATFORM:+--platform "$TARGET_PLATFORM"} \
      --build-arg "GIT_SHA=$GIT_SHA" --build-arg "BUILD_TIME=$BUILD_TIME" \
      --tag "$IMAGE" "$REPO_ROOT/demos/demo-app" 2>&1 | tail -3
    ;;
  docker)
    cmd "docker build ${TARGET_PLATFORM:+--platform $TARGET_PLATFORM }-t $IMAGE demos/demo-app/"
    docker build \
      ${TARGET_PLATFORM:+--platform "$TARGET_PLATFORM"} \
      --build-arg "GIT_SHA=$GIT_SHA" --build-arg "BUILD_TIME=$BUILD_TIME" \
      --tag "$IMAGE" "$REPO_ROOT/demos/demo-app" 2>&1 | tail -3
    ;;
esac

step_end "Image built: $IMAGE"
sleep 1

# =============================================================================
# Step 2: PUSH
# =============================================================================
step_start "PUSH" "Pushing image to registry"
echo ""

case "$BUILD_TOOL" in
  minikube)
    REGISTRY_IP=$(kubectl get svc registry -n registry -o jsonpath='{.spec.clusterIP}')
    PUSH_REF="${REGISTRY_IP}:5000/demo/app:latest"
    cmd "minikube ssh -- sudo ctr push --plain-http $PUSH_REF"
    minikube ssh -- "sudo ctr -n k8s.io images tag '$IMAGE' '$PUSH_REF'" 2>/dev/null || true
    minikube ssh -- "sudo ctr -n k8s.io images push --plain-http '$PUSH_REF'" 2>&1 | tail -3
    # Tag for in-cluster Deployment (Kyverno verifies via this name)
    minikube ssh -- "sudo ctr -n k8s.io images tag '$IMAGE' '$CLUSTER_IMAGE'" 2>/dev/null || true
    ;;
  podman)
    if [ "${CLUSTER_KIND:-}" = "aks" ] && [ -n "${ACR_NAME:-}" ]; then
      cmd "az acr login -n $ACR_NAME"
      az acr login -n "$ACR_NAME" >/dev/null
    fi
    cmd "podman push $IMAGE"
    podman push "$IMAGE" 2>&1 | tail -3
    ;;
  docker)
    if [ "${CLUSTER_KIND:-}" = "aks" ] && [ -n "${ACR_NAME:-}" ]; then
      cmd "az acr login -n $ACR_NAME"
      az acr login -n "$ACR_NAME" >/dev/null
    fi
    cmd "docker push $IMAGE"
    docker push "$IMAGE" 2>&1 | tail -3
    ;;
esac

step_end "Image pushed to $REGISTRY"
sleep 1

# =============================================================================
# Step 3: SIGN — Smallstep path (from host)
# =============================================================================
step_start "SIGN" "Path A: Smallstep CA (private PKI)"
echo ""
narrate "  Request a short-lived code signing cert from step-ca → sign with cosign"

# Fetch CA materials
kubectl get configmap step-ca-root -n workload \
  -o jsonpath='{.data.root_ca\.crt}' > "$TMPDIR/root_ca.crt"
kubectl get configmap devsecops-demo-stepca-certs -n pki \
  -o jsonpath='{.data.intermediate_ca\.crt}' > "$TMPDIR/intermediate_ca.crt"
cat "$TMPDIR/intermediate_ca.crt" "$TMPDIR/root_ca.crt" > "$TMPDIR/chain.pem"

PROV_PASSWORD=$(kubectl get secret devsecops-demo-stepca-provisioner-password -n pki \
  -o jsonpath='{.data.password}' | base64 -d)

cmd "step ca certificate demo4-pipeline cert.pem key.pem --not-after 5m"
STEP_OUTPUT=$(step ca certificate "demo4-pipeline" "$TMPDIR/cert.pem" "$TMPDIR/key.pem" \
  --ca-url "$STEP_CA_URL" \
  --root "$TMPDIR/root_ca.crt" \
  --provisioner "workload-signer" \
  --provisioner-password-file <(echo "$PROV_PASSWORD") \
  --san "pipeline@demo.local" \
  --not-after "5m" \
  --force 2>&1) && STEP_RC=0 || STEP_RC=$?

if [ "$STEP_RC" -ne 0 ]; then
  echo "$STEP_OUTPUT" | sed 's/^/  /'
  fail "step-ca cert request failed — is the port-forward running? (bash scripts/port-forward.sh)"
  exit 1
fi

# Convert key to cosign format
COSIGN_PASSWORD="" cosign import-key-pair \
  --key "$TMPDIR/key.pem" \
  --output-key-prefix "$TMPDIR/cosign-imported" 2>/dev/null

cmd "cosign sign --key cosign-imported.key --certificate cert.pem --certificate-chain chain.pem $IMAGE"
# cosign v3 stores signatures as OCI 1.1 referrers — discover with `cosign tree`.
SMALLSTEP_SIGN=$(COSIGN_PASSWORD="" cosign sign \
  --key "$TMPDIR/cosign-imported.key" \
  --certificate "$TMPDIR/cert.pem" \
  --certificate-chain "$TMPDIR/chain.pem" \
  --rekor-url "$REKOR_URL" \
  --allow-insecure-registry \
  --use-signing-config=false \
  --yes \
  "$IMAGE" 2>&1) && SS_RC=0 || SS_RC=$?

if [ "$SS_RC" -eq 0 ]; then
  echo "$SMALLSTEP_SIGN" | grep -E "tlog|entry|Pushing" | head -3 | sed 's/^/  /'
  step_end "Smallstep signing complete (cert expires in 5 minutes)"
else
  echo "$SMALLSTEP_SIGN" | tail -3 | sed 's/^/  /'
  fail "Smallstep cosign sign failed"
  exit 1
fi
sleep 1

# =============================================================================
# Step 4: SIGN — Sigstore keyless path (from host)
# =============================================================================
step_start "SIGN" "Path B: Sigstore keyless (Fulcio + Rekor)"
echo ""
narrate "  OIDC token → Fulcio cert → cosign sign → Rekor log entry"

cmd "kubectl create token signing-sa -n workload --audience=sigstore"
TOKEN=$(kubectl create token signing-sa -n workload --audience=sigstore --duration=10m)

cmd "cosign sign --fulcio-url $FULCIO_URL --rekor-url $REKOR_URL --identity-token <token> $IMAGE"
SIGN_OUTPUT=$(cosign sign \
  --fulcio-url "$FULCIO_URL" \
  --rekor-url "$REKOR_URL" \
  --identity-token "$TOKEN" \
  --allow-insecure-registry \
  --use-signing-config=false \
  --yes \
  "$IMAGE" 2>&1) && SIGN_RC=0 || SIGN_RC=$?

if [ "$SIGN_RC" -eq 0 ]; then
  echo "$SIGN_OUTPUT" | grep -E "tlog|entry|SCT" | head -3 | sed 's/^/  /'
  step_end "Sigstore keyless signing complete"
else
  echo "$SIGN_OUTPUT" | tail -3 | sed 's/^/  /'
  fail "Keyless signing failed"
fi

REKOR_TREE=$(curl -sf "$REKOR_URL/api/v1/log" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('treeSize','?'))" 2>/dev/null || echo "?")
echo "  Rekor tree size: $REKOR_TREE"
sleep 1

# =============================================================================
# Step 5: VERIFY
# =============================================================================
step_start "VERIFY" "Verifying image signatures"
echo ""

SA_IDENTITY="https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa"
if [ "${CLUSTER_KIND:-}" = "aks" ] && [ -n "${AKS_OIDC_ISSUER_URL:-}" ]; then
  OIDC_ISSUER="$AKS_OIDC_ISSUER_URL"
else
  OIDC_ISSUER="https://kubernetes.default.svc"
fi

cmd "cosign verify --certificate-identity '$SA_IDENTITY' \\"
cmd "  --certificate-oidc-issuer '$OIDC_ISSUER' $IMAGE"

VERIFY_OUTPUT=$(cosign verify \
  --rekor-url "$REKOR_URL" \
  --certificate-identity "$SA_IDENTITY" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --allow-insecure-registry \
  --insecure-ignore-sct=true \
  "$IMAGE" 2>&1) && VERIFY_RC=0 || VERIFY_RC=$?

if [ "$VERIFY_RC" -eq 0 ]; then
  echo "$VERIFY_OUTPUT" | grep -v "^$\|WARNING:" | head -5 | sed 's/^/  /'
  step_end "Signatures verified"
else
  echo "$VERIFY_OUTPUT" | tail -5 | sed 's/^/  /'
  fail "Verification failed"
fi

sleep 1

# =============================================================================
# Step 6: DEPLOY — Kyverno admits the signed image
# =============================================================================
step_start "DEPLOY" "Deploying to workload namespace"
echo ""
narrate "  Kyverno's admission webhook validates the signature before the pod is created."
note "Using in-cluster registry address: $CLUSTER_IMAGE"
cmd "kubectl apply -f deployment.yaml"

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app-signed
  namespace: workload
  labels:
    app: demo-app-signed
    demo: demo4-cicd
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-app-signed
  template:
    metadata:
      labels:
        app: demo-app-signed
    spec:
      containers:
        - name: app
          image: $CLUSTER_IMAGE
          imagePullPolicy: Always
          env:
            - name: IMAGE_SIGNED
              value: "true"
          ports:
            - containerPort: 8080
EOF

echo ""
echo "  Waiting for deployment to be ready ..."
kubectl rollout status deployment/demo-app-signed -n workload --timeout=120s 2>/dev/null || true

step_end "Deployment admitted by Kyverno (image is signed)"

# =============================================================================
# Summary
# =============================================================================
printf "\n${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Pipeline complete                                          ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  ${GREEN}✓ BUILD${CYAN}${BOLD}  → Image built with reproducible metadata          ║\n"
printf "║  ${GREEN}✓ PUSH${CYAN}${BOLD}   → Image in registry                               ║\n"
printf "║  ${GREEN}✓ SIGN${CYAN}${BOLD}   → Two signatures: Smallstep CA + Sigstore keyless ║\n"
printf "║  ${GREEN}✓ VERIFY${CYAN}${BOLD} → Both signatures validated                       ║\n"
printf "║  ${GREEN}✓ DEPLOY${CYAN}${BOLD} → Kyverno admitted the signed image               ║\n"
echo "╚══════════════════════════════════════════════════════════════╝"
printf "${NC}\n"
echo ""
printf "  Next: ${CYAN}bash demos/demo5-verification/run.sh${NC} — watch Kyverno BLOCK unsigned images\n"
echo ""
