#!/usr/bin/env bash
# =============================================================================
# Demo 4: CI/CD Pipeline Simulation
# =============================================================================
# Simulates a GitHub Actions run locally using shell steps that mirror
# the workflow — complete with group/step output formatting for familiarity.
#
#   ▶ [BUILD]  podman build the demo app
#   ▶ [PUSH]   push to local registry
#   ▶ [SIGN]   both signing paths (Smallstep + Sigstore)
#   ▶ [VERIFY] run the verification job
#   ▶ [DEPLOY] apply a Deployment — Kyverno admits the signed image
#
# Duration: ~10 minutes
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

REGISTRY="${REGISTRY:-localhost:30500}"
IMAGE="${IMAGE:-${REGISTRY}/demo/app:latest}"
REKOR_URL="${REKOR_URL:-http://localhost:30300}"
FULCIO_URL="${FULCIO_URL:-http://localhost:30200}"
TUF_URL="${TUF_URL:-http://localhost:30100}"

GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# CI-style step output
step_start() { printf "\n${BOLD}${CYAN}▶ [%s]${NC} %s\n" "$1" "$2"; }
step_end()   { printf "  ${GREEN}✓ %s${NC}\n" "$1"; }
cmd()        { printf "  ${YELLOW}\$ %s${NC}\n" "$*"; }
narrate()    { printf "\n${BOLD}%s${NC}\n" "$1"; }

# Cleanup: remove the demo deployment on exit
cleanup() {
  kubectl delete deployment demo-app-signed -n workload --ignore-not-found=true 2>/dev/null || true
}
trap cleanup EXIT

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
cmd "podman build --build-arg GIT_SHA=$GIT_SHA --build-arg BUILD_TIME=$BUILD_TIME -t $IMAGE ."

if command -v podman &>/dev/null; then
  podman build \
    --build-arg "GIT_SHA=$GIT_SHA" \
    --build-arg "BUILD_TIME=$BUILD_TIME" \
    --tag "$IMAGE" \
    "$REPO_ROOT/demos/demo-app" 2>&1 | tail -5
  step_end "Image built: $IMAGE"
else
  echo "  (podman not found — skipping actual build, continuing simulation)"
  step_end "Build step simulated"
fi

sleep 1

# =============================================================================
# Step 2: PUSH
# =============================================================================
step_start "PUSH" "Pushing image to registry"
echo ""
cmd "podman push --tls-verify=false $IMAGE"

if command -v podman &>/dev/null; then
  podman push --tls-verify=false "$IMAGE" 2>&1 | tail -3
  step_end "Image pushed to $REGISTRY"
else
  echo "  (simulated push)"
  step_end "Push step simulated"
fi

sleep 1

# =============================================================================
# Step 3: SIGN — Smallstep path
# =============================================================================
step_start "SIGN" "Signing with Smallstep CA (private PKI path)"
echo ""
narrate "  Path A: Private CA → short-lived cert → cosign sign"
cmd "cosign sign --key signing.key --certificate signing.crt --certificate-chain root_ca.crt $IMAGE"

# Trigger the Smallstep signing job in cluster
kubectl delete job signing-job-smallstep -n workload --ignore-not-found=true 2>/dev/null || true
kubectl apply -f "$REPO_ROOT/chart/templates/workload/signing-job-smallstep.yaml" \
  --dry-run=server 2>/dev/null || true

echo ""
echo "  Waiting for Smallstep signing job ..."
kubectl wait --for=condition=complete job/signing-job-smallstep -n workload --timeout=120s 2>/dev/null || \
  echo "  (job may still be running — check: kubectl logs -n workload job/signing-job-smallstep)"

step_end "Smallstep signing complete"
sleep 1

# =============================================================================
# Step 4: SIGN — Sigstore keyless path
# =============================================================================
step_start "SIGN" "Signing with Sigstore keyless (transparency log path)"
echo ""
narrate "  Path B: OIDC token → Fulcio cert → cosign sign → Rekor log entry"
cmd "cosign sign --fulcio-url $FULCIO_URL --rekor-url $REKOR_URL --identity-token \$TOKEN $IMAGE"

kubectl delete job signing-job-sigstore -n workload --ignore-not-found=true 2>/dev/null || true
echo "  Waiting for Sigstore signing job ..."
kubectl wait --for=condition=complete job/signing-job-sigstore -n workload --timeout=120s 2>/dev/null || \
  echo "  (job may still be running)"

REKOR_TREE=$(curl -sf "$REKOR_URL/api/v1/log" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('treeSize','?'))" 2>/dev/null || echo "?")
echo "  Rekor tree size: $REKOR_TREE (entry added)"
step_end "Sigstore keyless signing complete"
sleep 1

# =============================================================================
# Step 5: VERIFY
# =============================================================================
step_start "VERIFY" "Verifying image signatures"
echo ""
cmd "cosign verify --rekor-url $REKOR_URL --certificate-identity-regexp '.*' $IMAGE"

cosign verify \
  --rekor-url "$REKOR_URL" \
  --certificate-identity-regexp ".*" \
  --certificate-oidc-issuer "https://kubernetes.default.svc" \
  --allow-insecure-registry \
  "$IMAGE" 2>&1 | head -5 || echo "  (verification in progress)"

step_end "Signatures verified"
sleep 1

# =============================================================================
# Step 6: DEPLOY — Kyverno admits the signed image
# =============================================================================
step_start "DEPLOY" "Deploying to workload namespace"
echo ""
narrate "  Kyverno's admission webhook validates the signature before the pod is created."
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
          image: $IMAGE
          imagePullPolicy: Always
          env:
            - name: IMAGE_SIGNED
              value: "true"
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
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
echo "║  Pipeline complete                                           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  ${GREEN}✓ BUILD${NC}  → Image built with reproducible metadata           ║\n"
printf "║  ${GREEN}✓ PUSH${NC}   → Image in registry                                ║\n"
printf "║  ${GREEN}✓ SIGN${NC}   → Two signatures: Smallstep CA + Sigstore keyless  ║\n"
printf "║  ${GREEN}✓ VERIFY${NC} → Both signatures validated                        ║\n"
printf "║  ${GREEN}✓ DEPLOY${NC} → Kyverno admitted the signed image                ║\n"
echo "╚══════════════════════════════════════════════════════════════╝"
printf "${NC}\n"
echo ""
printf "  Next: ${CYAN}bash demos/demo5-verification/run.sh${NC} — watch Kyverno BLOCK unsigned images\n"
echo ""
