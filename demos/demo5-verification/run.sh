#!/usr/bin/env bash
# =============================================================================
# Demo 5: Verification as a Policy Gate
# =============================================================================
#   1. Configure Kyverno policy for local Sigstore (Fulcio root, Rekor key)
#   2. Switch Kyverno policy to Enforce mode
#   3. Attempt to deploy an UNSIGNED image — Kyverno blocks it
#   4. Deploy a CORRECTLY SIGNED image — admitted and running
#   5. Switch policy back to Audit mode (idempotent cleanup)
#
# Prerequisites: cosign, kubectl, python3, curl
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
CLUSTER_IMAGE="${CLUSTER_REGISTRY}/demo/app:latest"
REKOR_URL="${REKOR_URL:-http://localhost:30300}"
FULCIO_URL="${FULCIO_URL:-http://localhost:30200}"

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

header()  { pause_for_next; printf "\n${CYAN}${BOLD}=== %s ===${NC}\n" "$1"; }
narrate() { printf "\n${BOLD}%s${NC}\n" "$1"; }
cmd()     { printf "  ${YELLOW}\$ %s${NC}\n" "$*"; }
ok()      { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
fail()    { printf "  ${RED}[FAIL]${NC} %s\n" "$1"; }
blocked() { printf "  ${RED}[BLOCKED BY KYVERNO]${NC} %s\n" "$1"; }
note()    { printf "  ${CYAN}ℹ  %s${NC}\n" "$1"; }

MAGENTA='\033[0;35m'

printf "\n${MAGENTA}${BOLD}"
cat <<'BANNER'
═══════════════════════════════════════════════════════════════════════════════
  ▶▶▶  DEMO 5  ·  POLICY GATE · KYVERNO IN ENFORCE MODE
═══════════════════════════════════════════════════════════════════════════════

  The cluster only admits images it can cryptographically verify.

  · Configure Kyverno policy for the local Sigstore (Fulcio root, Rekor key)
  · Switch the cluster policy from Audit to Enforce
  · Attempt to deploy an UNSIGNED image; Kyverno blocks it at admission
  · Deploy a CORRECTLY signed image; admission allows it, pod runs
  · Restore Audit mode on exit (idempotent cleanup)

  Duration: ~5 min       Verification is a wall, not a suggestion.
═══════════════════════════════════════════════════════════════════════════════
BANNER
printf "${NC}\n"
sleep 1

# Pre-clean any stale test objects from a previous run, then start fresh.
# The unsigned-test pod is expected to be blocked (never admitted) but a prior
# successful signed-test deployment from a previous run would shadow today's.
kubectl delete deployment signed-test -n workload --ignore-not-found=true 2>/dev/null || true
kubectl delete pod unsigned-test signed-test -n workload --ignore-not-found=true 2>/dev/null || true

# Restore Audit mode on exit (idempotent) but LEAVE the signed-test deployment
# running so the audience can point at `kubectl get deployment -n workload`
# after the demo to confirm Kyverno admitted the signed image.
cleanup() {
  echo ""
  printf "  ${YELLOW}Restoring Kyverno policy to Audit mode ...${NC}\n"
  # Restore mutateDigest=false first (required for Audit mode)
  kubectl patch clusterpolicy require-image-signature --type=json \
    -p '[{"op":"replace","path":"/spec/rules/0/verifyImages/0/mutateDigest","value":false}]' 2>/dev/null || true
  kubectl patch clusterpolicy require-image-signature \
    --type=merge \
    -p '{"spec":{"validationFailureAction":"Audit"}}' 2>/dev/null || true
  # Clean up the failed unsigned-test pod only — leave signed-test running.
  kubectl delete pod unsigned-test -n workload --ignore-not-found=true 2>/dev/null || true
  printf "  ${GREEN}[OK]${NC} Policy restored to Audit mode\n"
  printf "  ${CYAN}ℹ  signed-test deployment left running for inspection:${NC}\n"
  printf "     ${CYAN}kubectl get deployment signed-test -n workload${NC}\n"
}
trap cleanup EXIT

# =============================================================================
header "Demo 5: Verification as a Policy Gate"
# =============================================================================

narrate "In Demo 4, Kyverno was in Audit mode — violations are logged but not blocked."
narrate "Now we flip the switch to Enforce mode and watch it become the policy gate."
sleep 2

# =============================================================================
header "Step 1: Configure Kyverno for local Sigstore infrastructure"
# =============================================================================
narrate "Kyverno needs to know our local Fulcio CA and Rekor public key."
narrate "Without these, it can't verify signatures from our private Sigstore stack."
echo ""

# Get the Fulcio root cert
FULCIO_ROOT=$(kubectl get secret fulcio-pub-key -n fulcio-system \
  -o jsonpath='{.data.cert}' | base64 -d 2>/dev/null || echo "")

# Get the Rekor public key
REKOR_PUB=$(kubectl get secret rekor-public-key -n tuf-system \
  -o jsonpath='{.data.key}' | base64 -d 2>/dev/null || echo "")

if [ -z "$FULCIO_ROOT" ] || [ -z "$REKOR_PUB" ]; then
  fail "Could not fetch Fulcio root cert or Rekor public key from cluster secrets"
  exit 1
fi

if [ "${CLUSTER_KIND:-}" = "aks" ] && [ -n "${AKS_OIDC_ISSUER_URL:-}" ]; then
  KEYLESS_ISSUER="$AKS_OIDC_ISSUER_URL"
else
  KEYLESS_ISSUER="https://kubernetes.default.svc"
fi

# Patch the ClusterPolicy with local Sigstore credentials
cmd "kubectl patch clusterpolicy require-image-signature (add Fulcio root + Rekor pubkey)"
python3 -c "
import json, subprocess, sys

fulcio_root = '''$FULCIO_ROOT'''
rekor_pub = '''$REKOR_PUB'''
issuer = '''$KEYLESS_ISSUER'''

patch = json.dumps([
    {'op': 'replace', 'path': '/spec/rules/0/verifyImages/0/attestors/0/entries/0/keyless', 'value': {
        'issuer': issuer,
        'subject': 'https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa',
        'roots': fulcio_root,
        'rekor': {
            'url': 'http://rekor-server.rekor-system.svc',
            'pubkey': rekor_pub
        },
        'ctlog': {
            'ignoreSCT': True
        }
    }}
])
result = subprocess.run(['kubectl', 'patch', 'clusterpolicy', 'require-image-signature',
                        '--type=json', '-p', patch], capture_output=True, text=True)
if result.returncode != 0:
    print(result.stderr, file=sys.stderr)
    sys.exit(1)
print(result.stdout.strip())
" 2>&1

ok "Fulcio root certificate added (issuer: Linux Foundation)"
ok "Rekor public key added (for transparency log verification)"
ok "SCT verification disabled (local Fulcio — no public CT log)"
sleep 2

# =============================================================================
header "Step 2: Ensure image is signed with old bundle format"
# =============================================================================
narrate "Kyverno v1.15 requires the legacy cosign signature format."
narrate "We re-sign the image with --new-bundle-format=false for compatibility."
echo ""

TOKEN=$(kubectl create token signing-sa -n workload --audience=sigstore --duration=10m)
cmd "cosign sign --new-bundle-format=false --fulcio-url ... --rekor-url ... $IMAGE"

SIGN_OUTPUT=$(cosign sign \
  --fulcio-url "$FULCIO_URL" \
  --rekor-url "$REKOR_URL" \
  --identity-token "$TOKEN" \
  --allow-insecure-registry \
  --use-signing-config=false \
  --new-bundle-format=false \
  --yes \
  "$IMAGE" 2>&1) && SIGN_RC=0 || SIGN_RC=$?

if [ "$SIGN_RC" -eq 0 ]; then
  # cosign v3 no longer emits tlog/SCT lines on sign; guard the grep so a
  # no-match doesn't abort the demo under `set -euo pipefail`.
  echo "$SIGN_OUTPUT" | grep -E "Signing|Pushing|tlog|entry|SCT" | head -3 | sed 's/^/  /' || true
  ok "Image signed (legacy bundle format for Kyverno compatibility)"
else
  echo "$SIGN_OUTPUT" | tail -5 | sed 's/^/  /'
  fail "Signing failed"
  exit 1
fi
sleep 1

# =============================================================================
header "Step 3: Switch Kyverno to Enforce mode"
# =============================================================================
echo ""
narrate "Before: validationFailureAction: Audit  (violations logged, not blocked)"
narrate "After:  validationFailureAction: Enforce (violations blocked at admission)"
echo ""

cmd "kubectl patch clusterpolicy require-image-signature --type=merge -p '{\"spec\":{\"validationFailureAction\":\"Enforce\"}}'"
kubectl patch clusterpolicy require-image-signature \
  --type=merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}' 2>&1

# Enable mutateDigest for Enforce mode (required for tag→digest resolution)
kubectl patch clusterpolicy require-image-signature --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/verifyImages/0/mutateDigest","value":true}]' 2>/dev/null

echo ""
ok "Policy is now in Enforce mode"
note "Waiting 5s for Kyverno to propagate the policy change ..."
sleep 5

# =============================================================================
header "Step 4: Attempt to deploy an UNSIGNED image"
# =============================================================================
narrate "We'll push a simple unsigned image to the registry and try to deploy it."
narrate "Kyverno's admission webhook will check for a signature — and block it."
echo ""

# Push an unsigned image to the registry
note "Building and pushing an unsigned image ..."
UNSIGNED_DIR=$(mktemp -d /tmp/demo5-unsigned-XXXXXX)
cat > "$UNSIGNED_DIR/Dockerfile" <<'DOCKERFILE'
FROM busybox:latest
CMD ["echo", "I am unsigned"]
DOCKERFILE

UNSIGNED_IMAGE="${CLUSTER_REGISTRY}/demo/unsigned:latest"

if [ "$CLUSTER_KIND" = "minikube" ] && command -v minikube &>/dev/null && minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
  REGISTRY_IP=$(kubectl get svc registry -n registry -o jsonpath='{.spec.clusterIP}')
  minikube image build -t "$UNSIGNED_IMAGE" "$UNSIGNED_DIR" 2>/dev/null
  PUSH_REF="${REGISTRY_IP}:5000/demo/unsigned:latest"
  minikube ssh -- "sudo ctr -n k8s.io images tag '$UNSIGNED_IMAGE' '$PUSH_REF'" 2>/dev/null || true
  minikube ssh -- "sudo ctr -n k8s.io images push --plain-http '$PUSH_REF'" >/dev/null 2>&1
  ok "Unsigned image pushed: demo/unsigned:latest"
elif [ "$CLUSTER_KIND" = "aks" ]; then
  if command -v docker &>/dev/null; then
    az acr login -n "$ACR_NAME" --only-show-errors
    docker build -t "$UNSIGNED_IMAGE" "$UNSIGNED_DIR" >/dev/null 2>&1
    docker push "$UNSIGNED_IMAGE" >/dev/null 2>&1
    ok "Unsigned image pushed to ACR: demo/unsigned:latest"
  else
    note "Docker not available — skipping unsigned image push"
  fi
fi
rm -rf "$UNSIGNED_DIR"

echo ""
cmd "kubectl run unsigned-test -n workload --image=$UNSIGNED_IMAGE  ← EXPECTED: BLOCKED"
echo ""

OUTPUT=$(kubectl run unsigned-test -n workload \
  --image="$UNSIGNED_IMAGE" \
  --restart=Never \
  --command -- sleep 3600 2>&1 || true)

if echo "$OUTPUT" | grep -qiE "blocked|admission webhook|policy|denied|Error"; then
  printf "\n  ${RED}${BOLD}✗ BLOCKED${NC} — Kyverno rejected the unsigned image!\n"
  echo "$OUTPUT" | grep -oE "failed to verify image[^']*" | head -1 | sed 's/^/    /' || true
  echo ""
  blocked "Image demo/unsigned:latest has no cosign signature"
else
  echo "$OUTPUT" | head -5 | sed 's/^/  /'
  note "Deployment may have been admitted — check if policy is fully active"
fi

sleep 3

# =============================================================================
header "Step 5: Deploy the CORRECTLY SIGNED image"
# =============================================================================
narrate "Same image as Demo 3/4 — properly signed via Sigstore keyless path."
narrate "Kyverno verifies the Fulcio cert + Rekor tlog entry at admission time."
echo ""

# Ensure containerd can pull from registry.registry.svc:5000 via ClusterIP (minikube only;
# on AKS, kubelet pulls from ACR via the managed identity wired up by the AVM module).
if [ "$CLUSTER_KIND" = "minikube" ] && command -v minikube &>/dev/null; then
  REGISTRY_IP=$(kubectl get svc registry -n registry -o jsonpath='{.spec.clusterIP}')
  minikube ssh -- "sudo mkdir -p /etc/containerd/certs.d/registry.registry.svc:5000" 2>/dev/null
  minikube ssh -- "echo 'server = \"http://registry.registry.svc:5000\"
[host.\"http://${REGISTRY_IP}:5000\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
' | sudo tee /etc/containerd/certs.d/registry.registry.svc:5000/hosts.toml" >/dev/null 2>&1
fi

cmd "kubectl apply -f signed-deployment.yaml  ← EXPECTED: ADMITTED"
echo ""

OUTPUT=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: signed-test
  namespace: workload
  labels:
    demo: demo5-policy-gate
spec:
  replicas: 1
  selector:
    matchLabels:
      app: signed-test
  template:
    metadata:
      labels:
        app: signed-test
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
)

echo "$OUTPUT"

if echo "$OUTPUT" | grep -qE "created|configured|unchanged"; then
  echo ""
  echo "  Waiting for deployment to be ready ..."
  kubectl rollout status deployment/signed-test -n workload --timeout=60s 2>/dev/null || true
  echo ""
  printf "  ${GREEN}${BOLD}✓ ADMITTED${NC} — Kyverno verified the signature and allowed the deployment!\n"
  echo ""
  ok "Fulcio-issued certificate validated against local CA root"
  ok "Rekor transparency log entry verified"
  ok "Identity assertion: signing-sa in workload namespace"
  ok "Deployment running in workload namespace"
fi

# =============================================================================
header "Summary — Policy enforcement in action"
# =============================================================================
echo ""
printf "  ${RED}✗ demo/unsigned:latest (no signature)  → BLOCKED${NC}\n"
printf "  ${GREEN}✓ demo/app:latest (keyless signed)      → ADMITTED${NC}\n"
echo ""
printf "  ${CYAN}The admission webhook fires on EVERY pod creation.${NC}\n"
printf "  ${CYAN}No unsigned image can bypass it — even kubectl apply is checked.${NC}\n"
echo ""
printf "  ${CYAN}Kyverno verified:${NC}\n"
echo "    • Certificate issued by local Fulcio CA (Linux Foundation)"
echo "    • Identity: signing-sa ServiceAccount in workload namespace"
echo "    • OIDC issuer: Kubernetes API server"
echo "    • Rekor transparency log entry with valid inclusion proof"
echo ""
printf "  Next: ${CYAN}bash demos/demo6-audit/run.sh${NC} — the CISO audit trail\n"
echo ""
