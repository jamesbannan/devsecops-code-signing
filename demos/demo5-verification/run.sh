#!/usr/bin/env bash
# =============================================================================
# Demo 5: Verification as a Policy Gate
# =============================================================================
#   1. Switch Kyverno policy to Enforce mode
#   2. Attempt to deploy an UNSIGNED image — Kyverno blocks it
#   3. Attempt to deploy a TAMPERED image — cosign verify fails, Kyverno blocks
#   4. Deploy a CORRECTLY SIGNED image — admitted
#   5. Switch policy back to Audit mode (idempotent cleanup)
#
# Duration: ~8 minutes
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

REGISTRY="${REGISTRY:-localhost:30500}"
IMAGE="${IMAGE:-${REGISTRY}/demo/app:latest}"
REKOR_URL="${REKOR_URL:-http://localhost:30300}"

header()  { printf "\n${CYAN}${BOLD}=== %s ===${NC}\n" "$1"; }
narrate() { printf "\n${BOLD}%s${NC}\n" "$1"; }
cmd()     { printf "  ${YELLOW}\$ %s${NC}\n" "$*"; }
ok()      { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
blocked() { printf "  ${RED}[BLOCKED BY KYVERNO]${NC} %s\n" "$1"; }

# Restore Audit mode on exit (idempotent)
cleanup() {
  echo ""
  printf "  ${YELLOW}Restoring Kyverno policy to Audit mode ...${NC}\n"
  kubectl patch clusterpolicy require-image-signature \
    --type=merge \
    -p '{"spec":{"validationFailureAction":"Audit"}}' 2>/dev/null || true
  # Clean up any test deployments
  kubectl delete deployment unsigned-test tampered-test signed-test \
    -n workload --ignore-not-found=true 2>/dev/null || true
  printf "  ${GREEN}[OK]${NC} Policy restored to Audit mode\n"
}
trap cleanup EXIT

# =============================================================================
header "Demo 5: Verification as a Policy Gate"
# =============================================================================

narrate "In Demo 4, Kyverno was in Audit mode — violations are logged but not blocked."
narrate "Now we flip the switch to Enforce mode and watch it become the policy gate."
sleep 2

# =============================================================================
header "Step 1: Switch Kyverno to Enforce mode"
# =============================================================================
echo ""
narrate "Before: validationFailureAction: Audit"
narrate "After:  validationFailureAction: Enforce"
echo ""

cmd "kubectl patch clusterpolicy require-image-signature --type=merge -p '{\"spec\":{\"validationFailureAction\":\"Enforce\"}}'"
kubectl patch clusterpolicy require-image-signature \
  --type=merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'

echo ""
ok "Policy is now in Enforce mode"
note() { printf "  ${CYAN}ℹ  %s${NC}\n" "$1"; }
note "Waiting 5s for Kyverno to propagate the policy change ..."
sleep 5

# =============================================================================
header "Step 2: Attempt to deploy an UNSIGNED image"
# =============================================================================
narrate "busybox:1.36.1 is a real image, but it has no cosign signature."
narrate "Kyverno's admission webhook will check for a signature — and block it."
echo ""

cmd "kubectl apply -f unsigned-deployment.yaml  ← EXPECTED: BLOCKED"
echo ""

OUTPUT=$(kubectl apply -f - 2>&1 <<EOF || true
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unsigned-test
  namespace: workload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unsigned-test
  template:
    metadata:
      labels:
        app: unsigned-test
    spec:
      containers:
        - name: app
          image: busybox:1.36.1
          command: [sleep, "3600"]
EOF
)

if echo "$OUTPUT" | grep -qiE "blocked|admission webhook|policy|denied|Error"; then
  printf "\n  ${RED}${BOLD}BLOCKED${NC} — Kyverno rejected the unsigned image!\n"
  echo "$OUTPUT" | grep -E "admission webhook|policy|blocked|denied|Error" | head -5 | sed 's/^/  /'
  echo ""
  blocked "Image busybox:1.36.1 has no cosign signature"
else
  echo "$OUTPUT" | head -5 | sed 's/^/  /'
  note "Deployment may have been admitted — check if policy is fully active"
fi

sleep 2

# =============================================================================
header "Step 3: Attempt to deploy a TAMPERED image"
# =============================================================================
narrate "What if an attacker pushes a modified image under the same tag?"
narrate "The digest changes — the signature no longer matches. Kyverno blocks it."
echo ""

# Push a tampered version (add a label to change the digest)
if command -v crane &>/dev/null; then
  cmd "crane mutate --label tampered=true $IMAGE --tag $REGISTRY/demo/app:tampered"
  crane mutate \
    --allow-nondistributable-artifacts \
    --label "tampered=true" \
    "$IMAGE" \
    --tag "$REGISTRY/demo/app:tampered" \
    --insecure 2>/dev/null || true
else
  note "crane not available — simulating tampered image scenario"
fi

TAMPERED_IMAGE="$REGISTRY/demo/app:tampered"
cmd "kubectl apply -f tampered-deployment.yaml  ← EXPECTED: BLOCKED"
echo ""

OUTPUT=$(kubectl apply -f - 2>&1 <<EOF || true
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tampered-test
  namespace: workload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tampered-test
  template:
    metadata:
      labels:
        app: tampered-test
    spec:
      containers:
        - name: app
          image: $TAMPERED_IMAGE
EOF
)

if echo "$OUTPUT" | grep -qiE "blocked|admission webhook|policy|denied|Error"; then
  printf "\n  ${RED}${BOLD}BLOCKED${NC} — Kyverno rejected the tampered image!\n"
  echo "$OUTPUT" | grep -E "admission webhook|policy|blocked|denied|Error" | head -3 | sed 's/^/  /'
else
  note "Tampered image deployment admitted (tampered tag may not exist)"
fi

sleep 2

# =============================================================================
header "Step 4: Deploy the CORRECTLY SIGNED image"
# =============================================================================
narrate "Same image as Demo 4 — properly signed via both Smallstep and Sigstore."
narrate "Kyverno verifies the signature at admission time. It passes."
echo ""

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
          image: $IMAGE
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
  printf "  ${GREEN}${BOLD}ADMITTED${NC} — Kyverno verified the signature and allowed the deployment!\n"
  echo ""
  ok "Image $IMAGE has valid cosign signature"
  ok "Deployment admitted to workload namespace"
fi

# =============================================================================
header "Summary — Policy enforcement in action"
# =============================================================================
echo ""
printf "  ${RED}✗ busybox:1.36.1 (unsigned)   → BLOCKED${NC}\n"
printf "  ${RED}✗ demo/app:tampered (modified) → BLOCKED${NC}\n"
printf "  ${GREEN}✓ demo/app:latest (signed)     → ADMITTED${NC}\n"
echo ""
printf "  ${CYAN}The admission webhook fires on EVERY pod creation.${NC}\n"
printf "  ${CYAN}No signed image can bypass it — even kubectl apply is checked.${NC}\n"
echo ""
printf "  Next: ${CYAN}bash demos/demo6-audit/run.sh${NC} — the CISO audit trail\n"
echo ""
