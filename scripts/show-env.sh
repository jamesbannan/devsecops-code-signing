#!/usr/bin/env bash
# =============================================================================
# show-env.sh — Audience-facing tour of the demo environment
# =============================================================================
# Designed to be run live in front of a room after install.sh and (optionally)
# build-and-push.sh have completed. Walks through three views:
#
#   1. Headline — all sigstore/PKI pods grouped by namespace
#   2. Per-component breakdown with one-line descriptions
#   3. The signed artefact — `cosign tree` against the pushed image
#
# Each section pauses for a keypress so the presenter controls the pace.
# Pass --no-pause to stream straight through (useful for CI / dry runs).
# =============================================================================
set -uo pipefail

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

PAUSE=1
for arg in "$@"; do
  case "$arg" in
    --no-pause) PAUSE=0 ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_cluster-detect.sh" >/dev/null 2>&1 || true
CLUSTER_KIND="${CLUSTER_KIND:-unknown}"

REGISTRY="${REGISTRY:-localhost:30500}"
IMAGE="${IMAGE:-${REGISTRY}/demo/app:latest}"

# Namespaces that make up the demo — order matters for the narrative
# (issuance → transparency → trust root → registry → enforcement).
COMPONENTS=(
  "pki|step-ca|Private CA issuing X.509 code-signing certs"
  "trillian-system|Trillian|Append-only Merkle log backing Rekor"
  "fulcio-system|Fulcio|Keyless cert authority — OIDC → short-lived cert"
  "rekor-system|Rekor|Public transparency log of every signature"
  "ctlog-system|CT log|Certificate Transparency for Fulcio-issued certs"
  "tuf-system|TUF|Signed root of trust for the whole sigstore stack"
  "registry|registry|OCI registry holding images + signatures + attestations"
  "policy|Kyverno|Admission controller enforcing signature policy"
)

hr() { printf "${DIM}%s${NC}\n" "────────────────────────────────────────────────────────────────────────"; }
section() { printf "\n${CYAN}${BOLD}» %s${NC}\n" "$1"; hr; }
note() { printf "${DIM}  %s${NC}\n" "$1"; }
cmd()  { printf "${YELLOW}\$ %s${NC}\n" "$1"; }

pause() {
  [[ "$PAUSE" -eq 0 ]] && return 0
  printf "\n${DIM}  ── press ENTER to continue ──${NC} "
  read -r _ || true
}

require() {
  if ! command -v "$1" &>/dev/null; then
    printf "${YELLOW}[skip]${NC} %s not installed — skipping section.\n" "$1"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Intro
# -----------------------------------------------------------------------------
clear 2>/dev/null || true
printf "${MAGENTA}${BOLD}\n"
cat <<'BANNER'
   ╔════════════════════════════════════════════════════════════════════╗
   ║          DevSecOps Code Signing — Environment Tour                 ║
   ╚════════════════════════════════════════════════════════════════════╝
BANNER
printf "${NC}"
note "Cluster: ${CLUSTER_KIND}"
note "Registry: ${REGISTRY}"
note "Image:    ${IMAGE}"
pause

# -----------------------------------------------------------------------------
# 1. Headline shot — every pod that powers the demo
# -----------------------------------------------------------------------------
section "1. The whole stack at a glance"
note "Filtered to demo namespaces — kube-system noise hidden."
cmd "kubectl get pods -A | grep -Ev 'kube-system|local-path|metrics-server|calico-system|tigera-operator'"
echo
kubectl get pods -A 2>/dev/null | \
  grep -Ev 'kube-system|local-path|metrics-server|calico-system|tigera-operator' || \
  printf "${YELLOW}  cluster unreachable — run install.sh first${NC}\n"
pause

# -----------------------------------------------------------------------------
# 2. Per-component breakdown
# -----------------------------------------------------------------------------
section "2. What each component does"
for entry in "${COMPONENTS[@]}"; do
  IFS='|' read -r ns label desc <<< "$entry"
  printf "\n${GREEN}${BOLD}▸ %-16s${NC} ${DIM}— %s${NC}\n" "$label" "$desc"
  if kubectl get ns "$ns" &>/dev/null; then
    kubectl get pods -n "$ns" --no-headers 2>/dev/null | \
      awk '{printf "    %-50s %-10s %s\n", $1, $3, $5}' || true
  else
    printf "    ${DIM}(namespace %s not present)${NC}\n" "$ns"
  fi
done
pause

# -----------------------------------------------------------------------------
# 3. The signed artefact
# -----------------------------------------------------------------------------
section "3. The signed image — signatures + attestations"
note "Anything attached to the image (sigs, SBOMs, provenance) appears below."
if require cosign && require crane; then
  cmd "crane manifest ${IMAGE} | jq -r '.config.digest'"
  digest="$(crane manifest "$IMAGE" 2>/dev/null | jq -r '.config.digest' 2>/dev/null || true)"
  if [[ -n "${digest:-}" && "$digest" != "null" ]]; then
    printf "  ${GREEN}%s${NC}\n\n" "$digest"
    cmd "cosign tree ${IMAGE}"
    echo
    cosign tree "$IMAGE" 2>&1 || \
      printf "${YELLOW}  cosign tree failed — has build-and-push.sh been run?${NC}\n"
  else
    printf "${YELLOW}  Image not found in registry. Run:${NC}\n"
    printf "    ${CYAN}bash demos/demo-app/build-and-push.sh${NC}\n"
  fi
else
  printf "${YELLOW}  install cosign + crane to see the signed artefact${NC}\n"
fi

hr
printf "${MAGENTA}${BOLD}Tour complete.${NC} Ready to start the demos.\n\n"
