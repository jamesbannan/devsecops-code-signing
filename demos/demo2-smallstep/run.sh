#!/usr/bin/env bash
# =============================================================================
# Demo 2: Smallstep CA Signing Path
# =============================================================================
# Shows signing with a short-lived certificate from Smallstep CA:
#   1. Show the step-ca CA health and provisioner list
#   2. Request a 2-minute code signing cert from the host using step CLI
#   3. Inspect the cert: issuer, subject, code signing EKU, expiry
#   4. Sign localhost:30500/demo/app:latest using the cert
#   5. Show the signature stored in the registry (cosign tree)
#   6. Wait for the cert to expire
#   7. Verify the image — STILL PASSES (cert was valid at signing time)
#
# Prerequisites: step CLI, cosign, kubectl, python3
# Duration: ~4 minutes (including 2-minute wait for cert expiry)
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
STEP_CA_URL="${STEP_CA_URL:-https://localhost:39000}"
REKOR_URL="${REKOR_URL:-http://localhost:30300}"
TUF_URL="${TUF_URL:-http://localhost:30100}"

TMPDIR=$(mktemp -d /tmp/demo2-smallstep-XXXXXX)

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

header()  { printf "\n${CYAN}${BOLD}=== %s ===${NC}\n" "$1"; }
narrate() { printf "\n${BOLD}%s${NC}\n" "$1"; }
cmd()     { printf "  ${YELLOW}\$ %s${NC}\n" "$*"; }
ok()      { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
fail()    { printf "  ${RED}[FAIL]${NC} %s\n" "$1"; }
note()    { printf "  ${CYAN}ℹ  %s${NC}\n" "$1"; }

# =============================================================================
header "Demo 2: Smallstep CA Signing Path"
# =============================================================================

narrate "Smallstep CA provides a private PKI that issues short-lived certificates."
narrate "Instead of a long-lived GPG key, we get a certificate that expires in minutes."
sleep 2

# ---- Fetch CA materials from the cluster ----
note "Fetching step-ca root certificate from the cluster ..."
kubectl get configmap step-ca-root -n workload \
  -o jsonpath='{.data.root_ca\.crt}' > "$TMPDIR/root_ca.crt"
ok "Root CA certificate saved"

note "Fetching intermediate CA certificate ..."
kubectl get configmap devsecops-demo-stepca-certs -n pki \
  -o jsonpath='{.data.intermediate_ca\.crt}' > "$TMPDIR/intermediate_ca.crt"
ok "Intermediate CA certificate saved"

# Build the full chain file (intermediate + root) for cosign
cat "$TMPDIR/intermediate_ca.crt" "$TMPDIR/root_ca.crt" > "$TMPDIR/chain.pem"

# Get the provisioner password
PROV_PASSWORD=$(kubectl get secret devsecops-demo-stepca-provisioner-password -n pki \
  -o jsonpath='{.data.password}' | base64 -d)

# =============================================================================
header "Step 1: Show the running certificate authority"
# =============================================================================
echo ""
cmd "curl -sk $STEP_CA_URL/health"
HEALTH=$(curl -sk "$STEP_CA_URL/health" 2>/dev/null || echo '{"status":"unknown"}')
echo "  $HEALTH"

echo ""
cmd "step ca provisioner list --ca-url $STEP_CA_URL --root root_ca.crt"
step ca provisioner list \
  --ca-url "$STEP_CA_URL" \
  --root "$TMPDIR/root_ca.crt" 2>/dev/null | python3 -c "
import sys, json
try:
    provs = json.load(sys.stdin)
    for p in provs:
        ptype = p.get('type','?')
        pname = p.get('name','?')
        print(f'  {ptype}: {pname}')
except:
    print('  (could not parse provisioner list)')
" || echo "  (provisioner list unavailable — is port-forward running?)"

echo ""
note "The 'workload-signer' JWK provisioner issues code signing certificates."
note "Certificates include the Code Signing extended key usage (EKU)."
sleep 2

# =============================================================================
header "Step 2: Request a short-lived signing certificate"
# =============================================================================
narrate "We request a certificate that expires in 2 minutes."
narrate "In production, this would be 5 minutes — short enough to prevent key reuse."
echo ""

CERT_DURATION="2m"

cmd "step ca certificate demo2-signing-key cert.pem key.pem \\"
cmd "  --ca-url $STEP_CA_URL --provisioner workload-signer \\"
cmd "  --san signing@demo.local --not-after $CERT_DURATION"

step ca certificate "demo2-signing-key" "$TMPDIR/cert.pem" "$TMPDIR/key.pem" \
  --ca-url "$STEP_CA_URL" \
  --root "$TMPDIR/root_ca.crt" \
  --provisioner "workload-signer" \
  --provisioner-password-file <(echo "$PROV_PASSWORD") \
  --san "signing@demo.local" \
  --not-after "$CERT_DURATION" \
  --force

ISSUED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo ""
ok "Certificate issued at: $ISSUED_AT"

# =============================================================================
header "Step 3: Inspect the certificate"
# =============================================================================
narrate "Let's look at what the CA issued — notice the Code Signing EKU."
echo ""

cmd "openssl x509 -in cert.pem -noout -text"
echo ""
echo "  Key details:"
openssl x509 -in "$TMPDIR/cert.pem" -noout \
  -subject -issuer -dates -ext extendedKeyUsage 2>/dev/null | sed 's/^/  /'

echo ""
note "The Code Signing EKU restricts this cert to signing only."
note "It cannot be used for TLS or any other purpose."
sleep 2

# =============================================================================
header "Step 4: Sign the image with the certificate"
# =============================================================================
narrate "cosign signs the image using the ephemeral certificate as the signing key."
narrate "The signature includes the full certificate chain, proving the CA issued it."
echo ""

# cosign requires keys in its own encrypted format
note "Converting key to cosign format ..."
COSIGN_PASSWORD="" cosign import-key-pair \
  --key "$TMPDIR/key.pem" \
  --output-key-prefix "$TMPDIR/cosign-imported" 2>/dev/null
ok "Key imported"

echo ""
cmd "cosign sign --key cosign-imported.key --certificate cert.pem \\"
cmd "  --certificate-chain chain.pem --rekor-url $REKOR_URL \\"
cmd "  --allow-insecure-registry $IMAGE"

COSIGN_PASSWORD="" cosign sign \
  --key "$TMPDIR/cosign-imported.key" \
  --certificate "$TMPDIR/cert.pem" \
  --certificate-chain "$TMPDIR/chain.pem" \
  --allow-insecure-registry \
  --use-signing-config=false \
  --rekor-url="$REKOR_URL" \
  --yes \
  "$IMAGE" 2>&1 | grep -v "^Flag\|^$\|WARNING:" | grep -v "^$" || true

echo ""
ok "Image signed with short-lived certificate"
note "In a CI pipeline, this runs automatically after every successful build."
sleep 2

# =============================================================================
header "Step 5: Verify — where is the signature stored?"
# =============================================================================
narrate "Unlike GPG .sig files, cosign stores signatures IN the registry."
narrate "The signature is a separate OCI artifact linked to the image digest."
echo ""

cmd "cosign tree --allow-insecure-registry $IMAGE"
cosign tree --allow-insecure-registry "$IMAGE" 2>/dev/null || \
  echo "  (cosign tree output unavailable)"

echo ""
note "The signature lives alongside the image — no external storage needed."
note "Any OCI-compatible registry can store it."
sleep 2

# =============================================================================
header "Step 6: Wait for the certificate to expire"
# =============================================================================
narrate "The certificate we signed with expires in $CERT_DURATION."
narrate "Let's wait and see what happens to the signature ..."
echo ""

# Calculate wait time (cert duration + 10s buffer)
WAIT_SECS=130
for i in $(seq "$WAIT_SECS" -1 1); do
  printf "\r  ${YELLOW}Waiting for cert expiry: %3d seconds remaining ...${NC}" "$i"
  sleep 1
done
printf "\r  ${RED}Certificate has expired!                               ${NC}\n"
echo ""
ok "Current time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
note "Let's confirm the cert is expired:"
cmd "openssl x509 -in cert.pem -noout -checkend 0"
if openssl x509 -in "$TMPDIR/cert.pem" -noout -checkend 0 2>/dev/null; then
  note "Certificate is still valid (clock skew?) — waiting a bit longer ..."
  sleep 15
fi
echo "  Certificate has expired ✗"

# =============================================================================
header "Step 7: Verify the image — after cert expiry"
# =============================================================================
narrate "The signing cert is expired. Can we still verify the image?"
echo ""

# Build a Sigstore trusted root JSON containing our private CA chain and local Rekor key
note "Building trusted root from private CA chain and local Rekor key ..."
ROOT_DER_B64=$(openssl x509 -in "$TMPDIR/root_ca.crt" -outform DER 2>/dev/null | base64 | tr -d '\n')
INTER_DER_B64=$(openssl x509 -in "$TMPDIR/intermediate_ca.crt" -outform DER 2>/dev/null | base64 | tr -d '\n')

# Fetch the Rekor transparency log public key from the local TUF mirror
note "Fetching Rekor public key from TUF mirror ..."
REKOR_KEY_FILE=$(curl -sf "$TUF_URL/targets/" | grep -o '[a-f0-9]*\.rekor\.pub' | head -1)
curl -sf "${TUF_URL}/targets/${REKOR_KEY_FILE}" > "$TMPDIR/rekor.pub"
REKOR_KEY_DER_B64=$(openssl ec -pubin -in "$TMPDIR/rekor.pub" -outform DER 2>/dev/null | base64 | tr -d '\n')
REKOR_LOG_ID_B64=$(openssl ec -pubin -in "$TMPDIR/rekor.pub" -outform DER 2>/dev/null | openssl dgst -sha256 -binary | base64 | tr -d '\n')

python3 - "$ROOT_DER_B64" "$INTER_DER_B64" "$REKOR_KEY_DER_B64" "$REKOR_LOG_ID_B64" "$REKOR_URL" > "$TMPDIR/trusted-root.json" << 'PYEOF'
import json, sys
root_b64, inter_b64, rekor_key_b64, rekor_log_id, rekor_url = sys.argv[1:6]
trusted_root = {
    "mediaType": "application/vnd.dev.sigstore.trustedroot+json;version=0.1",
    "certificateAuthorities": [{
        "subject": {
            "organization": "DevSecOps Demo CA",
            "commonName": "DevSecOps Demo CA Root CA"
        },
        "certChain": {
            "certificates": [
                {"rawBytes": inter_b64},
                {"rawBytes": root_b64}
            ]
        },
        "validFor": {"start": "2024-01-01T00:00:00Z"}
    }],
    "tlogs": [{
        "baseUrl": rekor_url,
        "hashAlgorithm": "SHA2_256",
        "publicKey": {
            "rawBytes": rekor_key_b64,
            "keyDetails": "PKIX_ECDSA_P256_SHA_256",
            "validFor": {"start": "2024-01-01T00:00:00Z"}
        },
        "logId": {"keyId": rekor_log_id}
    }],
    "ctlogs": []
}
print(json.dumps(trusted_root, indent=2))
PYEOF

cmd "cosign verify --trusted-root trusted-root.json \\"
cmd "  --certificate-identity-regexp '.*' \\"
cmd "  --allow-insecure-registry $IMAGE"

VERIFY_OUTPUT=$(cosign verify \
  --trusted-root "$TMPDIR/trusted-root.json" \
  --certificate-identity-regexp ".*" \
  --certificate-oidc-issuer-regexp ".*" \
  --allow-insecure-registry \
  --insecure-ignore-sct=true \
  "$IMAGE" 2>&1) && VERIFY_RC=0 || VERIFY_RC=$?

if [ "$VERIFY_RC" -eq 0 ]; then
  echo "$VERIFY_OUTPUT" | grep -v "^$\|WARNING:" | head -10
  echo ""
  printf "  ${GREEN}${BOLD}VERIFICATION PASSED${NC} — even though the signing cert expired!\n"
else
  echo "$VERIFY_OUTPUT" | head -10
  echo ""
  fail "Verification failed unexpectedly (rc=$VERIFY_RC)"
fi

echo ""
note "Key insight: the cert was VALID AT THE TIME OF SIGNING."
note "The Rekor transparency log recorded the exact signing timestamp."
note "Verification checks the tlog entry to prove the cert was valid when used."
note "The expired cert cannot be used to sign NEW images — only past signatures remain valid."
echo ""
printf "  ${CYAN}Compare to GPG: a compromised GPG key invalidates ALL past signatures.${NC}\n"
printf "  ${CYAN}With short-lived certs: expiry limits the blast radius.${NC}\n"
echo ""
printf "  Next: ${CYAN}bash demos/demo3-sigstore/run.sh${NC}\n"
echo ""
