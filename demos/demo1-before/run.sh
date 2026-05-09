#!/usr/bin/env bash
# =============================================================================
# Demo 1: The Painful Baseline — Manual GPG signing
# =============================================================================
# Shows what container image signing looked like before automated tooling:
#   - Generate a GPG key pair (ephemeral, in temp dir)
#   - Manually sign a container image digest with GPG
#   - Show the resulting .sig file
#   - Narrate the problems: no audit trail, no expiry, key lives forever
#
# Audience takeaway: "This is what we're replacing."
# Duration: ~5 minutes
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

TMPDIR=$(mktemp -d /tmp/demo1-gpg-XXXXXX)

# Cleanup on exit — idempotent, safe to run multiple times
cleanup() {
  rm -rf "$TMPDIR"
  # Remove any temp GPG home
  gpgconf --homedir "$TMPDIR/.gnupg" --kill gpg-agent 2>/dev/null || true
}
trap cleanup EXIT

header()  { printf "\n${CYAN}${BOLD}=== %s ===${NC}\n" "$1"; }
narrate() { printf "\n${BOLD}%s${NC}\n" "$1"; }
cmd()     { printf "  ${YELLOW}\$ %s${NC}\n" "$*"; }
ok()      { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
note()    { printf "  ${RED}⚠  %s${NC}\n" "$1"; }

# =============================================================================
header "Demo 1: The Painful Baseline"
# =============================================================================

narrate "Before automated signing, teams signed container images manually."
narrate "Let's recreate that workflow — and see exactly why it was painful."

sleep 2

# =============================================================================
header "Step 1: Generate a GPG key pair"
# =============================================================================
narrate "# This is what we're replacing — a long-lived GPG key with no expiry"
echo ""

export GNUPGHOME="$TMPDIR/.gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

# Create a batch key specification
cat > "$TMPDIR/keygen.batch" <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: Demo Signing Key
Name-Email: signing@demo.local
Expire-Date: 0
%commit
EOF

cmd "gpg --batch --gen-key keygen.batch"
gpg --batch --gen-key "$TMPDIR/keygen.batch" 2>&1 | tail -5

KEY_ID=$(gpg --list-secret-keys --keyid-format LONG 2>/dev/null | \
  grep "^sec" | awk '{print $2}' | cut -d/ -f2 | head -1)

ok "GPG key generated: $KEY_ID"

echo ""
note "Problem 1: This key has NO expiry. It lives forever unless manually revoked."
note "Problem 2: The key is stored on disk. If the build server is compromised, all past signatures are compromised."
note "Problem 3: There is NO audit trail. No central log of what was signed, when, by whom."
sleep 3

# =============================================================================
header "Step 2: Get the image digest to sign"
# =============================================================================
narrate "We need the image manifest digest — the 'true identity' of the image."
echo ""

cmd "curl -s http://$REGISTRY/v2/demo/app/manifests/latest | sha256sum"
DIGEST=$(curl -sf \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "http://$REGISTRY/v2/demo/app/manifests/latest" 2>/dev/null | \
  sha256sum | awk '{print $1}' || echo "abc123example...")

echo "  Digest: sha256:$DIGEST"
echo "$DIGEST" > "$TMPDIR/digest.txt"
ok "Image digest captured"

echo ""
note "Problem 4: We have to manually compute and track this digest."
note "           If we sign the wrong digest, verification silently fails."
sleep 2

# =============================================================================
header "Step 3: Sign the digest with GPG"
# =============================================================================
narrate "Now we sign the digest file. This is the 'signing event'."
echo ""

cmd "gpg --armor --detach-sign --output digest.sig digest.txt"
gpg --armor --detach-sign \
  --output "$TMPDIR/digest.sig" \
  "$TMPDIR/digest.txt"

ok "Signature created: digest.sig"
echo ""
cmd "cat digest.sig"
cat "$TMPDIR/digest.sig"

echo ""
note "Problem 5: Where does this .sig file live? S3? Git repo? Attached to the image?"
note "           There is no standard location. Every team invents their own storage scheme."
sleep 2

# =============================================================================
header "Step 4: Verify the signature"
# =============================================================================
narrate "Verification works — but only if you have the public key."
echo ""

cmd "gpg --verify digest.sig digest.txt"
if gpg --verify "$TMPDIR/digest.sig" "$TMPDIR/digest.txt" 2>&1; then
  ok "Signature verified"
fi

echo ""
note "Problem 6: How does the production cluster know which GPG keys to trust?"
note "           How does it get updated when keys change? Who maintains the keyring?"
sleep 3

# =============================================================================
header "Summary — Why the old way fails"
# =============================================================================
echo ""
printf "  ${RED}What we just demonstrated:${NC}\n"
echo ""
printf "  ✗  Long-lived keys that never expire\n"
printf "  ✗  Keys stored on disk with no automatic rotation\n"
printf "  ✗  No central audit trail — can't answer 'who signed this image?'\n"
printf "  ✗  Manual digest tracking — error-prone and unscalable\n"
printf "  ✗  Signatures stored out-of-band — no standard discoverability\n"
printf "  ✗  No identity binding — the key doesn't prove WHO signed it\n"
printf "  ✗  No pipeline integration — signing is a manual step\n"
echo ""
printf "  ${GREEN}What we'll show next:${NC}\n"
echo ""
printf "  ✓  Short-lived certificates (5 minutes) — no long-lived keys\n"
printf "  ✓  Identity-bound signatures — tied to a workload or CI identity\n"
printf "  ✓  Immutable transparency log — tamper-evident audit trail\n"
printf "  ✓  Signatures stored in the registry — discoverable, standard\n"
printf "  ✓  Policy enforcement — unsigned images are automatically blocked\n"
echo ""
printf "  ${CYAN}Next: bash demos/demo2-smallstep/run.sh${NC}\n"
echo ""
