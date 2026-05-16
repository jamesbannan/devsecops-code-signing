#!/usr/bin/env bash
# =============================================================================
# Demo 3: Sigstore Keyless Signing Path
# =============================================================================
#   1. Show the OIDC token contents (decoded JWT — issuer, subject, audience)
#   2. Keyless sign from the host: Fulcio issues a cert, Rekor logs the event
#   3. Show the Rekor transparency log entry (log index, tree size)
#   4. Extract the certificate from the signature (who signed, when, which identity)
#   5. cosign verify with explicit identity assertions
#   6. Pull the Rekor entry directly via the API and show the raw JSON
#
# Prerequisites: cosign, kubectl, python3, curl
# Duration: ~5 minutes
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/_cluster-detect.sh
source "$REPO_ROOT/scripts/_cluster-detect.sh"

REGISTRY="${REGISTRY:-localhost:30500}"
IMAGE="${IMAGE:-${REGISTRY}/demo/app:latest}"
REKOR_URL="${REKOR_URL:-http://localhost:30300}"
FULCIO_URL="${FULCIO_URL:-http://localhost:30200}"
TUF_URL="${TUF_URL:-http://localhost:30100}"
if [ "${CLUSTER_KIND:-}" = "aks" ] && [ -n "${AKS_OIDC_ISSUER_URL:-}" ]; then
  OIDC_ISSUER="$AKS_OIDC_ISSUER_URL"
else
  OIDC_ISSUER="https://kubernetes.default.svc"
fi

TMPDIR=$(mktemp -d /tmp/demo3-sigstore-XXXXXX)

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

printf "\n${CYAN}${BOLD}"
cat <<'BANNER'
═══════════════════════════════════════════════════════════════════════════════
  ▶▶▶  DEMO 3  ·  SIGSTORE KEYLESS SIGNING
═══════════════════════════════════════════════════════════════════════════════

  OIDC identity · ephemeral Fulcio certs · transparent Rekor log.

  · Decode the OIDC token (issuer, subject, audience)
  · Keyless sign; Fulcio issues a 10-minute cert, Rekor logs the event
  · Show the Rekor transparency-log entry (log index, tree size)
  · Extract the cert from the signature; show who signed, when, from where
  · Verify with explicit identity assertions; pull the raw Rekor entry

  Duration: ~5 min       No long-lived keys exist at any point.
═══════════════════════════════════════════════════════════════════════════════
BANNER
printf "${NC}\n"
sleep 1

# =============================================================================
header "Demo 3: Sigstore Keyless Signing"
# =============================================================================

narrate "Sigstore keyless signing has NO long-lived keys at all."
narrate "Identity comes from an OIDC token — the same mechanism used for cloud IAM."
sleep 2

# =============================================================================
header "Step 1: The OIDC identity token"
# =============================================================================
narrate "Every Kubernetes pod gets a ServiceAccount JWT — a standard OIDC token."
narrate "Let's look at what's inside it."
echo ""

cmd "kubectl create token signing-sa -n workload --audience=sigstore"
TOKEN=$(kubectl create token signing-sa -n workload --audience=sigstore --duration=10m 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
  PAYLOAD=$(echo "$TOKEN" | cut -d. -f2 | \
    python3 -c "import sys,base64,json; \
      p=sys.stdin.read().strip(); \
      p+='='*(-len(p)%4); \
      print(json.dumps(json.loads(base64.b64decode(p)), indent=2))" 2>/dev/null || echo "{}")

  echo ""
  printf "  ${CYAN}JWT payload:${NC}\n"
  echo "$PAYLOAD" | head -20 | sed 's/^/    /'
else
  cat <<'EOF'
  JWT payload (example):
  {
    "iss": "https://kubernetes.default.svc",
    "sub": "system:serviceaccount:workload:signing-sa",
    "aud": ["sigstore"],
    "exp": 1700000600,
    "iat": 1700000000
  }
EOF
fi

echo ""
note "Key fields:"
note "  iss (issuer):  $OIDC_ISSUER — who issued this token"
note "  sub (subject): system:serviceaccount:workload:signing-sa — the workload's identity"
note "  aud (audience): sigstore — scoped to Sigstore only"
note "  exp (expiry):  10 minutes from now — token is short-lived"
sleep 3

# =============================================================================
header "Step 2: Keyless signing — Fulcio issues the cert"
# =============================================================================
narrate "cosign presents the OIDC token to Fulcio."
narrate "Fulcio verifies the token and issues a certificate binding the identity to a key."
narrate "The whole process takes milliseconds — no human interaction needed."
echo ""

note "What happens behind the scenes:"
echo "  1. cosign generates an ephemeral key pair (exists only in memory)"
echo "  2. cosign sends the OIDC token + public key to Fulcio"
echo "  3. Fulcio verifies the OIDC token against the Kubernetes JWKS endpoint"
echo "  4. Fulcio issues a 10-minute certificate with the SA identity as the SAN"
echo "  5. cosign signs the image digest with the ephemeral private key"
echo "  6. cosign submits the signature + cert to Rekor (transparency log)"
echo "  7. Rekor returns a log entry index and inclusion proof"
echo "  8. cosign stores the signature + Rekor bundle in the registry"
echo "  9. The ephemeral private key is discarded — it never touches disk"
echo ""

cmd "cosign sign --fulcio-url $FULCIO_URL --rekor-url $REKOR_URL \\"
cmd "  --identity-token <token> --allow-insecure-registry $IMAGE"

# Get a fresh token and sign.
# cosign v3+ stores signatures exclusively as OCI 1.1 referrers (subject manifests
# pointing at the image digest). There is no longer a separate '.sig' tag in the
# registry — discover signatures via `cosign tree` or the /referrers API.
TOKEN=$(kubectl create token signing-sa -n workload --audience=sigstore --duration=10m)
SIGN_OUTPUT=$(cosign sign \
  --fulcio-url "$FULCIO_URL" \
  --rekor-url "$REKOR_URL" \
  --identity-token "$TOKEN" \
  --allow-insecure-registry \
  --use-signing-config=false \
  --yes \
  "$IMAGE" 2>&1) && SIGN_RC=0 || SIGN_RC=$?

if [ "$SIGN_RC" -eq 0 ]; then
  # Extract the tlog index from the output
  TLOG_INDEX=$(echo "$SIGN_OUTPUT" | grep -o 'index: [0-9]*' | head -1 | awk '{print $2}')
  echo "$SIGN_OUTPUT" | grep -E "tlog entry|SCT" | sed 's/^/  /'
  echo ""
  ok "Image signed keylessly (tlog index: ${TLOG_INDEX:-?})"

  # Show the user *where* the signature landed in the registry. cosign v3 always
  # stores signatures as OCI 1.1 referrers — no separate '.sig' tag is created.
  IMAGE_DIGEST=$(cosign triangulate --type=digest --allow-insecure-registry "$IMAGE" 2>/dev/null \
    | awk -F'@' '{print $2}')
  if [ -n "$IMAGE_DIGEST" ]; then
    note "Signature attached as OCI 1.1 referrer of:"
    note "  ${REGISTRY}/demo/app@${IMAGE_DIGEST}"
    note "  (no separate '.sig' tag — cosign v3 uses referrers exclusively)"
    note "Inspect with: cosign tree ${REGISTRY}/demo/app@${IMAGE_DIGEST}"
    if [ "${CLUSTER_KIND:-}" = "aks" ] && [ -n "${ACR_NAME:-}" ]; then
      note "Or in ACR:    az acr manifest list-referrers -r ${ACR_NAME} -n demo/app@${IMAGE_DIGEST}"
      note "ACR Portal:   Repositories → demo/app → click the image digest → Referrers tab"
    fi
  fi
else
  echo "$SIGN_OUTPUT" | tail -5 | sed 's/^/  /'
  fail "Keyless signing failed"
fi

note "No keys were stored anywhere. The certificate expires in 10 minutes."
note "The only permanent record is the Rekor transparency log entry."
sleep 2

# =============================================================================
header "Step 3: The Rekor transparency log entry"
# =============================================================================
narrate "Every keyless signing event is recorded in the Rekor transparency log."
narrate "This is the tamper-evident audit trail — no private infrastructure needed."
echo ""

cmd "curl -s $REKOR_URL/api/v1/log"
TREE=$(curl -sf "$REKOR_URL/api/v1/log" 2>/dev/null || echo '{}')
echo "$TREE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('  treeSize:', d.get('treeSize','?'))
print('  rootHash:', d.get('rootHash','?')[:40]+'...')
" 2>/dev/null || echo "  (Rekor log info)"

echo ""
note "The treeSize increases with every new signing event."
note "The rootHash changes when entries are added — verifiable by anyone."
note "Any tampering with the log is mathematically detectable (Merkle tree)."
sleep 2

# =============================================================================
header "Step 4: The certificate in the signature"
# =============================================================================
narrate "The signature stored in the registry contains the ephemeral certificate."
narrate "Anyone can extract it and see exactly WHO signed the image."
echo ""

cmd "cosign download signature --allow-insecure-registry $IMAGE"

# Extract the Fulcio-issued cert from the signature bundle
cosign download signature --allow-insecure-registry "$IMAGE" 2>/dev/null | python3 -c "
import sys, json, base64, subprocess
for line in sys.stdin:
    try:
        d = json.loads(line)
        vm = d.get('verificationMaterial', {})
        cert_data = vm.get('certificate', {}).get('rawBytes', '')
        if not cert_data:
            continue
        der = base64.b64decode(cert_data)
        proc = subprocess.run(
            ['openssl', 'x509', '-inform', 'DER', '-noout', '-subject', '-issuer',
             '-dates', '-ext', 'subjectAltName'],
            input=der, capture_output=True)
        text = proc.stdout.decode().strip()
        if 'Linux Foundation' in text:
            print('  Fulcio-issued certificate:')
            for l in text.split(chr(10)):
                print('   ', l.strip())
            break
    except:
        pass
" 2>/dev/null || echo "  (could not extract certificate)"

echo ""
note "The certificate is embedded IN the signature — no separate key distribution needed."
note "The OIDC issuer and subject are cryptographically bound to the signature."
note "Fulcio's issuer (Linux Foundation) proves this came from the Sigstore CA."
sleep 2

# =============================================================================
header "Step 5: Verify with identity assertions"
# =============================================================================
narrate "cosign verify checks not just the signature, but the IDENTITY that signed it."
narrate "We can require a specific issuer and subject — preventing signature substitution."
echo ""

SA_IDENTITY="https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa"

cmd "cosign verify \\"
cmd "  --certificate-identity '$SA_IDENTITY' \\"
cmd "  --certificate-oidc-issuer '$OIDC_ISSUER' \\"
cmd "  --allow-insecure-registry $IMAGE"

VERIFY_OUTPUT=$(cosign verify \
  --rekor-url "$REKOR_URL" \
  --certificate-identity "$SA_IDENTITY" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --allow-insecure-registry \
  --insecure-ignore-sct=true \
  "$IMAGE" 2>&1) && VERIFY_RC=0 || VERIFY_RC=$?

if [ "$VERIFY_RC" -eq 0 ]; then
  echo "$VERIFY_OUTPUT" | grep -v "^$\|WARNING:" | head -5 | sed 's/^/  /'
  echo ""
  printf "  ${GREEN}${BOLD}VERIFIED${NC} — signed by the expected workload identity\n"
else
  echo "$VERIFY_OUTPUT" | head -5 | sed 's/^/  /'
  echo ""
  fail "Verification failed (rc=$VERIFY_RC)"
fi

echo ""
note "The --certificate-identity flag ensures only the expected ServiceAccount signed this."
note "An attacker with a different identity token would be rejected."
sleep 2

# =============================================================================
header "Step 6: Raw Rekor entry via API"
# =============================================================================
narrate "The Rekor API lets anyone retrieve and verify log entries independently."
narrate "You don't need cosign — any HTTP client can audit the signing history."
echo ""

# Use the tlog index from the signing step, or fall back to the latest
LOG_INDEX="${TLOG_INDEX:-0}"
cmd "curl -s '$REKOR_URL/api/v1/log/entries?logIndex=$LOG_INDEX'"
ENTRY=$(curl -sf "$REKOR_URL/api/v1/log/entries?logIndex=$LOG_INDEX" 2>/dev/null || echo '{}')
echo "$ENTRY" | python3 -c "
import sys,json,base64
d=json.load(sys.stdin)
for k,v in d.items():
  body=v.get('body','')
  try:
    decoded=json.loads(base64.b64decode(body+'=='))
    print('  Entry UUID:  ', k[:24]+'...')
    print('  Kind:        ', decoded.get('kind','?'))
    print('  API version: ', decoded.get('apiVersion','?'))
    spec = decoded.get('spec', {})
    sig_content = spec.get('signature', {}).get('content', '')
    if sig_content:
      print('  Has signature: yes')
    pk = spec.get('signature', {}).get('publicKey', {}).get('content', '')
    if pk:
      import base64 as b64
      cert_pem = b64.b64decode(pk).decode('utf-8', errors='replace')
      if 'BEGIN CERTIFICATE' in cert_pem:
        print('  Has certificate: yes (Fulcio-issued)')
  except: pass
" 2>/dev/null || echo "  (Rekor entry — log index $LOG_INDEX)"

echo ""
note "This entry is permanent and append-only."
note "Even the Rekor operators cannot delete or modify entries."
note "Anyone can verify the Merkle tree inclusion proof."
echo ""
printf "  ${CYAN}Next: bash demos/demo4-cicd/run.sh${NC}\n"
echo ""
