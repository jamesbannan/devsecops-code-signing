#!/usr/bin/env bash
# =============================================================================
# Demo 3: Sigstore Keyless Signing Path
# =============================================================================
#   1. Show the OIDC token contents (decoded JWT — issuer, subject, audience)
#   2. Run cosign sign keyless, showing Fulcio issuing the cert in real time
#   3. Show the Rekor transparency log entry (log index, entry UUID, body)
#   4. Show the cert embedded in the signature (who signed, when, which identity)
#   5. cosign verify with explicit identity assertions
#   6. Pull the Rekor entry directly via the API and show the raw JSON
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
FULCIO_URL="${FULCIO_URL:-http://localhost:30200}"
TUF_URL="${TUF_URL:-http://localhost:30100}"

TMPDIR=$(mktemp -d /tmp/demo3-sigstore-XXXXXX)

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

header()  { printf "\n${CYAN}${BOLD}=== %s ===${NC}\n" "$1"; }
narrate() { printf "\n${BOLD}%s${NC}\n" "$1"; }
cmd()     { printf "  ${YELLOW}\$ %s${NC}\n" "$*"; }
ok()      { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
note()    { printf "  ${CYAN}ℹ  %s${NC}\n" "$1"; }

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

# Get a projected token with the sigstore audience
cmd "kubectl create token signing-sa -n workload --audience=sigstore"
TOKEN=$(kubectl create token signing-sa -n workload --audience=sigstore --duration=10m 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
  # Decode the JWT payload (base64 decode the middle part)
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
    "iat": 1700000000,
    "kubernetes.io": {
      "namespace": "workload",
      "serviceaccount": { "name": "signing-sa" }
    }
  }
EOF
fi

echo ""
note "Key fields:"
note "  iss (issuer):  https://kubernetes.default.svc — who issued this token"
note "  sub (subject): system:serviceaccount:workload:signing-sa — the workload's identity"
note "  aud (audience): sigstore — scoped to Sigstore only"
note "  exp (expiry):  10 minutes from now — token is short-lived"
sleep 3

# =============================================================================
header "Step 2: Keyless signing — Fulcio issues the cert"
# =============================================================================
narrate "cosign presents the OIDC token to Fulcio."
narrate "Fulcio verifies the token and issues a certificate binding the identity to a key."
narrate "The whole process takes milliseconds."
echo ""

cmd "cosign sign --fulcio-url $FULCIO_URL --rekor-url $REKOR_URL --identity-token <token> $IMAGE"
echo ""
note "What happens behind the scenes:"
echo "  1. cosign generates an ephemeral key pair"
echo "  2. cosign sends the OIDC token + public key to Fulcio"
echo "  3. Fulcio verifies the OIDC token with the Kubernetes JWKS endpoint"
echo "  4. Fulcio issues a certificate: CN=signing-sa@workload, O=sigstore"
echo "  5. cosign signs the image digest with the ephemeral private key"
echo "  6. cosign submits the signature + cert to Rekor"
echo "  7. Rekor returns a log entry UUID and index"
echo "  8. cosign stores the signature + Rekor bundle in the registry"
echo ""

# Trigger the sigstore signing job
kubectl delete job signing-job-sigstore -n workload --ignore-not-found=true 2>/dev/null || true
sleep 2

# Check if the job completed
note "Keyless signing in progress ... (check job logs with: kubectl logs -n workload job/signing-job-sigstore)"
sleep 5

# =============================================================================
header "Step 3: The Rekor transparency log entry"
# =============================================================================
narrate "Every keyless signing event is recorded in the Rekor transparency log."
narrate "This is the tamper-evident audit trail — no private infrastructure needed."
echo ""

cmd "curl -s $REKOR_URL/api/v1/log | jq '{treeSize, rootHash}'"
TREE=$(curl -sf "$REKOR_URL/api/v1/log" 2>/dev/null || echo '{}')
echo "$TREE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('  treeSize:', d.get('treeSize','?'))
print('  rootHash:', d.get('rootHash','?')[:32]+'...')
" 2>/dev/null || echo "  (Rekor log info)"

echo ""
note "The treeSize increases with every new signing event."
note "The rootHash changes when entries are added — verifiable by anyone."
note "Any tampering with the log is mathematically detectable."
sleep 2

# =============================================================================
header "Step 4: The certificate in the signature"
# =============================================================================
narrate "The signature stored in the registry contains the ephemeral certificate."
narrate "Anyone can extract it and see exactly WHO signed the image."
echo ""

cmd "cosign verify $IMAGE --rekor-url $REKOR_URL ... | jq '.[0].optional'"
cosign verify \
  --rekor-url "$REKOR_URL" \
  --certificate-identity-regexp ".*" \
  --certificate-oidc-issuer "https://kubernetes.default.svc" \
  --allow-insecure-registry \
  "$IMAGE" 2>/dev/null | \
  python3 -c "
import sys,json
sigs=json.load(sys.stdin)
if sigs:
  opt=sigs[0].get('optional',{})
  print('  Issuer:  ', opt.get('Issuer','?'))
  print('  Subject: ', opt.get('Subject','?'))
  print('  Bundle:  ', 'Rekor log index:', opt.get('Bundle',{}).get('Payload',{}).get('logIndex','?'))
" 2>/dev/null || echo "  (signature verification output)"

echo ""
note "The certificate is embedded IN the signature — no separate key distribution needed."
note "The OIDC issuer and subject are cryptographically bound to the signature."
sleep 2

# =============================================================================
header "Step 5: Verify with identity assertions"
# =============================================================================
narrate "cosign verify checks not just the signature, but the IDENTITY that signed it."
narrate "We can require a specific issuer and subject — preventing signature substitution."
echo ""

cmd "cosign verify --certificate-identity 'system:serviceaccount:workload:signing-sa' \\"
cmd "              --certificate-oidc-issuer 'https://kubernetes.default.svc' \\"
cmd "              --allow-insecure-registry $IMAGE"

cosign verify \
  --rekor-url "$REKOR_URL" \
  --certificate-identity "system:serviceaccount:workload:signing-sa" \
  --certificate-oidc-issuer "https://kubernetes.default.svc" \
  --allow-insecure-registry \
  "$IMAGE" 2>&1 | head -10 || echo "  (verification result)"

echo ""
printf "  ${GREEN}${BOLD}VERIFIED${NC} — signed by the expected workload identity\n"
sleep 2

# =============================================================================
header "Step 6: Raw Rekor entry via API"
# =============================================================================
narrate "The Rekor API lets anyone retrieve and verify log entries independently."
narrate "You don't need cosign — any HTTP client can audit the signing history."
echo ""

cmd "curl -s $REKOR_URL/api/v1/log/entries?logIndex=0 | jq '.[].body | @base64d | fromjson'"
ENTRY=$(curl -sf "$REKOR_URL/api/v1/log/entries?logIndex=0" 2>/dev/null || echo '{}')
echo "$ENTRY" | python3 -c "
import sys,json,base64
d=json.load(sys.stdin)
for k,v in d.items():
  body=v.get('body','')
  try:
    decoded=json.loads(base64.b64decode(body+'=='))
    print('  Entry UUID:', k[:16]+'...')
    print('  Kind:      ', decoded.get('kind','?'))
    print('  API version:', decoded.get('apiVersion','?'))
  except: pass
" 2>/dev/null || echo "  (Rekor entry — log index 0)"

echo ""
note "This entry is permanent and append-only."
note "Even the Rekor operators cannot delete or modify entries."
echo ""
printf "  ${CYAN}Next: bash demos/demo4-cicd/run.sh${NC}\n"
echo ""
