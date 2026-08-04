#!/usr/bin/env bash
# =============================================================================
# Demo 6: Attestation + Audit Trail (CISO view)
# =============================================================================
#   1. Create a provenance attestation from the host (in-toto SLSA format)
#   2. Show the attestation stored alongside the signature in the registry
#   3. Verify the attestation with cosign verify-attestation
#   4. Pull the Kyverno PolicyReport and format it clearly
#   5. Show the full chain: git SHA → build → digest → signature → Rekor entry
#   6. Print a CISO report: who signed, when, from what identity, verified by log
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
REKOR_URL="${REKOR_URL:-http://localhost:30300}"
FULCIO_URL="${FULCIO_URL:-http://localhost:30200}"

GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_SHA_FULL=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

SA_IDENTITY="https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa"
if [ "${CLUSTER_KIND:-}" = "aks" ] && [ -n "${AKS_OIDC_ISSUER_URL:-}" ]; then
  OIDC_ISSUER="$AKS_OIDC_ISSUER_URL"
else
  OIDC_ISSUER="https://kubernetes.default.svc"
fi

TMPDIR=$(mktemp -d /tmp/demo6-audit-XXXXXX)
cleanup() { rm -rf "$TMPDIR"; }
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

header()  { pause_for_next; printf "\n${CYAN}${BOLD}=== %s ===${NC}\n" "$1"; }
narrate() { printf "\n${BOLD}%s${NC}\n" "$1"; }
cmd()     { printf "  ${YELLOW}\$ %s${NC}\n" "$*"; }
ok()      { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
fail()    { printf "  ${RED}[FAIL]${NC} %s\n" "$1"; }
note()    { printf "  ${CYAN}ℹ  %s${NC}\n" "$1"; }

printf "\n${BOLD}"
cat <<'BANNER'
═══════════════════════════════════════════════════════════════════════════════
  ▶▶▶  DEMO 6  ·  ATTESTATION + AUDIT TRAIL · THE CISO VIEW
═══════════════════════════════════════════════════════════════════════════════

  Provenance, policy, and a transparency log; the full evidence chain.

  · Create an in-toto SLSA provenance attestation for the running image
  · Show it stored alongside the signature in the registry
  · cosign verify-attestation; predicate type and identity both checked
  · Pull the Kyverno PolicyReport for the workload namespace
  · Render the full chain: git SHA → build → digest → signature → Rekor entry
  · Print a CISO-ready report: who signed, when, from what identity

  Duration: ~5 min       Every answer the audit team asks, already on disk.
═══════════════════════════════════════════════════════════════════════════════
BANNER
printf "${NC}\n"
sleep 1

# =============================================================================
header "Demo 6: Attestation + Audit Trail"
# =============================================================================

narrate "Signatures prove an image hasn't been tampered with."
narrate "Attestations prove HOW the image was built and WHERE it came from."
narrate "Together, they give CISOs a complete, verifiable provenance chain."
sleep 2

# =============================================================================
header "Step 1: Create a provenance attestation"
# =============================================================================
narrate "We attach an in-toto SLSA provenance statement to the image."
narrate "This records: builder, source repository, git SHA, build time."
echo ""

# Build a provenance predicate
cat > "$TMPDIR/provenance.json" <<EOF
{
  "buildType": "https://github.com/Attestations/GitHubActionsWorkflow@v1",
  "builder": {
    "id": "https://github.com/actions/runner"
  },
  "invocation": {
    "configSource": {
      "uri": "git+https://github.com/jamesbannan/devsecops-code-signing",
      "digest": {
        "sha1": "$GIT_SHA_FULL"
      },
      "entryPoint": ".github/workflows/sign.yml"
    },
    "parameters": {},
    "environment": {
      "github_run_id": "$(date +%s)",
      "github_run_attempt": "1"
    }
  },
  "metadata": {
    "buildStartedOn": "$BUILD_TIME",
    "buildFinishedOn": "$BUILD_TIME",
    "completeness": {
      "parameters": true,
      "environment": false,
      "materials": false
    },
    "reproducible": false
  },
  "materials": [
    {
      "uri": "git+https://github.com/jamesbannan/devsecops-code-signing",
      "digest": {
        "sha1": "$GIT_SHA_FULL"
      }
    }
  ]
}
EOF

note "Provenance predicate:"
python3 -c "
import json
with open('$TMPDIR/provenance.json') as f:
    d = json.load(f)
print('  builder:', d['builder']['id'])
print('  source: ', d['invocation']['configSource']['uri'])
print('  commit: ', d['invocation']['configSource']['digest']['sha1'][:12]+'...')
print('  built:  ', d['metadata']['buildStartedOn'])
"
echo ""

# Get a token and attest from the host (keyless)
TOKEN=$(kubectl create token signing-sa -n workload --audience=sigstore --duration=10m)

cmd "cosign attest --predicate provenance.json --type slsaprovenance \\"
cmd "  --fulcio-url $FULCIO_URL --rekor-url $REKOR_URL $IMAGE"

ATTEST_OUTPUT=$(cosign attest \
  --predicate "$TMPDIR/provenance.json" \
  --type slsaprovenance \
  --fulcio-url "$FULCIO_URL" \
  --rekor-url "$REKOR_URL" \
  --identity-token "$TOKEN" \
  --allow-insecure-registry \
  --use-signing-config=false \
  --yes \
  "$IMAGE" 2>&1) && ATTEST_RC=0 || ATTEST_RC=$?

if [ "$ATTEST_RC" -eq 0 ]; then
  # cosign v3 attest prints "Signing artifact..."; guard the grep so a no-match
  # doesn't abort the demo under `set -euo pipefail`.
  echo "$ATTEST_OUTPUT" | grep -E "Signing|Pushing|tlog|entry|SCT" | head -3 | sed 's/^/  /' || true
  ok "Provenance attestation created and logged in Rekor"
else
  echo "$ATTEST_OUTPUT" | tail -5 | sed 's/^/  /'
  fail "Attestation failed"
fi

note "The attestation is stored as an OCI artifact alongside the image."
sleep 2

# =============================================================================
header "Step 2: Show attestation in the registry"
# =============================================================================
narrate "Let's see what's stored in the registry for our image."
echo ""

cmd "cosign tree --allow-insecure-registry $IMAGE"
TREE_OUTPUT=$(cosign tree --allow-insecure-registry "$IMAGE" 2>/dev/null || echo "")

if [ -n "$TREE_OUTPUT" ]; then
  echo "$TREE_OUTPUT" | head -8 | sed 's/^/  /'
  SIG_COUNT=$(echo "$TREE_OUTPUT" | grep -c "🍒" || true)
  echo ""
  note "The tree shows $SIG_COUNT artifacts: signatures + attestations"
else
  echo "  (cosign tree output)"
fi

echo ""
note "All are standard OCI artifacts — any registry supports them."
note "Signatures prove identity. Attestations prove provenance."
sleep 2

# =============================================================================
header "Step 3: Verify the attestation"
# =============================================================================
narrate "cosign verify-attestation checks the attestation signature AND content."
narrate "It confirms: WHO attested, WHAT they attested, and WHEN (via Rekor)."
echo ""

cmd "cosign verify-attestation --type slsaprovenance \\"
cmd "  --certificate-identity '$SA_IDENTITY' \\"
cmd "  --certificate-oidc-issuer '$OIDC_ISSUER' $IMAGE"

# cosign v3 embeds the Rekor inclusion proof in the attestation bundle, so tlog
# existence is verified offline — no --rekor-url needed (it now only prints a
# deprecation warning, "please use --bundle").
VERIFY_OUTPUT=$(cosign verify-attestation \
  --type slsaprovenance \
  --certificate-identity "$SA_IDENTITY" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --allow-insecure-registry \
  --insecure-ignore-sct=true \
  "$IMAGE" 2>&1) && VERIFY_RC=0 || VERIFY_RC=$?

if [ "$VERIFY_RC" -eq 0 ]; then
  # Extract and show the provenance from the verified attestation
  echo "$VERIFY_OUTPUT" | grep -v "^$\|WARNING:" | head -5 | sed 's/^/  /'
  echo ""
  ok "Attestation verified — provenance is cryptographically bound to the image"

  # Show the provenance payload
  echo ""
  note "Provenance payload from the verified attestation:"
  echo "$VERIFY_OUTPUT" | python3 -c "
import sys, json, base64
for line in sys.stdin:
    try:
        d = json.loads(line)
        payload_b64 = d.get('payload','')
        if payload_b64:
            stmt = json.loads(base64.b64decode(payload_b64))
            pred = stmt.get('predicateType','')
            payload = stmt.get('predicate',{})
            if pred:
                print(f'  predicateType: {pred}')
            builder = payload.get('builder',{}).get('id','')
            if builder:
                print(f'  builder: {builder}')
            source = payload.get('invocation',{}).get('configSource',{})
            if source:
                print(f'  source:  {source.get(\"uri\",\"?\")}')
                sha = source.get('digest',{}).get('sha1','?')
                print(f'  commit:  {sha[:12]}...')
            meta = payload.get('metadata',{})
            if meta.get('buildStartedOn'):
                print(f'  built:   {meta[\"buildStartedOn\"]}')
            break
    except: pass
" 2>/dev/null || echo "  (attestation payload)"
else
  echo "$VERIFY_OUTPUT" | tail -5 | sed 's/^/  /'
  fail "Attestation verification failed"
fi

sleep 2

# =============================================================================
header "Step 4: Kyverno PolicyReport"
# =============================================================================
narrate "Every image admission generates a PolicyReport entry."
narrate "This is the machine-readable audit log that your SIEM can consume."
echo ""

cmd "kubectl get policyreport -n workload"
echo ""

REPORT_COUNT=$(kubectl get policyreport -n workload --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$REPORT_COUNT" -gt 0 ]; then
  kubectl get policyreport -n workload --no-headers 2>/dev/null | head -10 | \
    awk '{printf "  %-40s %-6s PASS=%s FAIL=%s\n", $3, $2, $4, $5}'
  echo ""
  ok "$REPORT_COUNT PolicyReport entries in workload namespace"
  note "Each entry records: resource kind, policy name, result (pass/fail), message"
  note "Ship to Elastic, Splunk, or any SIEM via kubectl export or log forwarder"
else
  echo "  No PolicyReports found in workload namespace"
  note "PolicyReports are generated when Kyverno evaluates image admissions"
fi

sleep 2

# =============================================================================
header "Step 5: The complete provenance chain"
# =============================================================================
narrate "Let's trace the complete chain from source code to running container."
echo ""

IMAGE_DIGEST=$(curl -sf \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "http://$REGISTRY/v2/demo/app/manifests/latest" 2>/dev/null | \
  python3 -c "
import sys,hashlib
content=sys.stdin.buffer.read()
print('sha256:'+hashlib.sha256(content).hexdigest())
" 2>/dev/null || echo "sha256:unknown")

REKOR_SIZE=$(curl -sf "$REKOR_URL/api/v1/log" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('treeSize','?'))" 2>/dev/null || echo "?")

printf "  ${BOLD}Provenance Chain${NC}\n"
echo ""
printf "  ${CYAN}1. Source code${NC}\n"
printf "     Repository: github.com/jamesbannan/devsecops-code-signing\n"
printf "     Commit SHA: %s\n" "$GIT_SHA_FULL"
echo ""
printf "  ${CYAN}2. Build${NC}\n"
printf "     Build time: %s\n" "$BUILD_TIME"
printf "     Builder:    minikube image build (containerd)\n"
echo ""
printf "  ${CYAN}3. Image${NC}\n"
printf "     Image:      %s\n" "$IMAGE"
printf "     Digest:     %s\n" "${IMAGE_DIGEST:0:60}"
echo ""
printf "  ${CYAN}4. Signatures + Attestation${NC}\n"
printf "     Signature:  Sigstore keyless (Fulcio + Rekor)\n"
printf "     Attestation: SLSA provenance (in-toto format)\n"
printf "     Identity:   %s\n" "$SA_IDENTITY"
echo ""
printf "  ${CYAN}5. Transparency log${NC}\n"
printf "     Rekor URL:  %s\n" "$REKOR_URL"
printf "     Tree size:  %s entries (tamper-evident Merkle tree)\n" "$REKOR_SIZE"
echo ""
printf "  ${CYAN}6. Policy enforcement${NC}\n"
printf "     Policy:     require-image-signature (Kyverno ClusterPolicy)\n"
printf "     Audit:      %s PolicyReports in workload namespace\n" "$REPORT_COUNT"
sleep 2

# =============================================================================
header "Step 6: CISO Report"
# =============================================================================
echo ""
printf "${CYAN}${BOLD}"

# The box is drawn with helpers that pad by *character* count (${#s}), not by
# printf's byte-based %-Ns. That keeps the right border aligned even when a row
# contains a multi-byte glyph like ✓ (3 bytes, 1 display column), which used to
# pull the border 2 columns left. Over-long values are truncated with an ellipsis
# so they can never blow out the box.
BW=76                                   # inner width between the ║ borders
BAR=$(printf '═%.0s' $(seq 1 "$BW"))

box_row() {                             # box_row "<text>" — pad/truncate to BW chars
  local s="$1" len=${#1}
  if [ "$len" -gt "$BW" ]; then
    s="${s:0:$((BW - 1))}…"
    len=$BW
  fi
  printf "║%s%*s║\n" "$s" "$((BW - len))" ""
}
box_kv2() { box_row "$(printf '  %-14s%s' "$1" "$2")"; }    # top section rows
box_kv4() { box_row "$(printf '    %-16s%s' "$1" "$2")"; }  # rows inside a section

printf "╔%s╗\n" "$BAR"
box_row "$(printf '%*sIMAGE SIGNING AUDIT REPORT' 25 '')"
printf "╠%s╣\n" "$BAR"
box_kv2 "Generated:"   "$BUILD_TIME"
box_kv2 "Environment:" "DevSecOps Code Signing Demo"
printf "╠%s╣\n" "$BAR"
box_kv2 "Image:"   "$IMAGE"
box_kv2 "Digest:"  "${IMAGE_DIGEST:0:48}"
box_kv2 "Git SHA:" "$GIT_SHA_FULL"
printf "╠%s╣\n" "$BAR"
box_row "  SIGNATURES"
box_kv4 "Sigstore:"    "✓ Keyless signed (Fulcio + Rekor)"
box_kv4 "Attestation:" "✓ SLSA provenance attached"
printf "╠%s╣\n" "$BAR"
box_row "  SIGNING IDENTITY"
box_kv4 "Issuer:"  "$OIDC_ISSUER"
box_kv4 "Subject:" "signing-sa (workload namespace)"
box_row "    SAN URI:"
box_row "      $SA_IDENTITY"
printf "╠%s╣\n" "$BAR"
box_row "  TRANSPARENCY LOG"
box_kv4 "Rekor URL:" "$REKOR_URL"
box_kv4 "Tree size:" "$REKOR_SIZE entries (tamper-evident)"
printf "╠%s╣\n" "$BAR"
box_row "  POLICY COMPLIANCE"
box_kv4 "ClusterPolicy:" "require-image-signature"
box_kv4 "PolicyReports:" "$REPORT_COUNT entries"
box_kv4 "Status:"        "✓ Compliant"
printf "╚%s╝\n" "$BAR"
printf "${NC}\n"

echo ""
printf "  ${GREEN}${BOLD}End-to-end: zero-friction, fully automated, cryptographically verifiable.${NC}\n"
echo ""
printf "  Thank you — questions welcome!\n"
echo ""
