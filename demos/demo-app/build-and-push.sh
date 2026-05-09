#!/usr/bin/env bash
# =============================================================================
# build-and-push.sh — Build and push the demo app to the local registry
# =============================================================================
# Builds the container image and pushes to localhost:30500/demo/app:latest.
#
# Build strategy (in order of preference):
#   1. minikube image build + ctr push  (works on all platforms including macOS)
#   2. podman build + podman push       (requires VM→host networking)
#   3. docker build + docker push       (requires VM→host networking)
#
# On macOS, podman/docker daemons run inside a VM and usually cannot reach
# host-side port-forwards. minikube image build is the most reliable option.
#
# Usage:
#   bash demos/demo-app/build-and-push.sh
#   IMAGE_TAG=v1.2.3 bash demos/demo-app/build-and-push.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

REGISTRY="${REGISTRY:-localhost:30500}"
IMAGE_NAME="${IMAGE_NAME:-demo/app}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="$REGISTRY/$IMAGE_NAME:$IMAGE_TAG"

GIT_SHA=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

header() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
info()   { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()     { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
cmd()    { printf "  ${YELLOW}\$ %s${NC}\n" "$1"; }

header "Building demo-app"
info "Image:      $FULL_IMAGE"
info "Git SHA:    $GIT_SHA"
info "Build time: $BUILD_TIME"

# --- Detect build tool ---
BUILD_TOOL=""
if command -v minikube &>/dev/null && minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
  BUILD_TOOL="minikube"
elif command -v podman &>/dev/null; then
  BUILD_TOOL="podman"
elif command -v docker &>/dev/null; then
  BUILD_TOOL="docker"
else
  printf "  ${RED}[ERROR]${NC} No container build tool found (minikube, podman, or docker).\n"
  exit 1
fi
info "Build tool: $BUILD_TOOL"

# --- Build ---
header "Building container image"

case "$BUILD_TOOL" in
  minikube)
    cmd "minikube image build -t $FULL_IMAGE $SCRIPT_DIR"
    minikube image build \
      -t "$FULL_IMAGE" \
      "$SCRIPT_DIR"
    ;;
  podman)
    cmd "podman build -t $FULL_IMAGE $SCRIPT_DIR"
    podman build \
      --tls-verify=false \
      --build-arg "GIT_SHA=$GIT_SHA" \
      --build-arg "BUILD_TIME=$BUILD_TIME" \
      --tag "$FULL_IMAGE" \
      "$SCRIPT_DIR"
    ;;
  docker)
    cmd "docker build -t $FULL_IMAGE $SCRIPT_DIR"
    docker build \
      --build-arg "GIT_SHA=$GIT_SHA" \
      --build-arg "BUILD_TIME=$BUILD_TIME" \
      --tag "$FULL_IMAGE" \
      "$SCRIPT_DIR"
    ;;
esac

ok "Image built: $FULL_IMAGE"

# --- Verify local registry is reachable ---
header "Checking registry connectivity"
if ! curl -sf "http://$REGISTRY/v2/" -o /dev/null; then
  printf "  ${RED}[ERROR]${NC} Registry at %s is not reachable.\n" "$REGISTRY"
  echo "  Ensure port-forwards are running: bash scripts/port-forward.sh"
  exit 1
fi
ok "Registry reachable at $REGISTRY"

# --- Push ---
header "Pushing image to registry"

case "$BUILD_TOOL" in
  minikube)
    # minikube image build stores the image in containerd on the node.
    # Push to the in-cluster registry using ctr with the registry's ClusterIP,
    # since buildkit's DNS resolver can't reach cluster service names.
    REGISTRY_IP=$(kubectl get svc registry -n registry -o jsonpath='{.spec.clusterIP}')
    PUSH_REF="${REGISTRY_IP}:5000/$IMAGE_NAME:$IMAGE_TAG"
    info "Tagging for in-cluster push: $PUSH_REF"
    minikube ssh -- "sudo ctr -n k8s.io images tag '$FULL_IMAGE' '$PUSH_REF'" 2>/dev/null || true
    cmd "minikube ssh -- sudo ctr -n k8s.io images push --plain-http $PUSH_REF"
    minikube ssh -- "sudo ctr -n k8s.io images push --plain-http '$PUSH_REF'" 2>&1
    ;;
  podman)
    cmd "podman push --tls-verify=false $FULL_IMAGE"
    podman push --tls-verify=false "$FULL_IMAGE"
    ;;
  docker)
    cmd "docker push $FULL_IMAGE"
    docker push "$FULL_IMAGE"
    ;;
esac

ok "Image pushed: $FULL_IMAGE"

# --- Verify the push by pulling the manifest ---
header "Verifying push"
DIGEST=$(curl -sf \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "http://$REGISTRY/v2/$IMAGE_NAME/manifests/$IMAGE_TAG" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('config',{}).get('digest',''))" \
  2>/dev/null || echo "")

if [ -n "$DIGEST" ]; then
  ok "Registry manifest verified: $DIGEST"
else
  printf "  ${YELLOW}[WARN]${NC} Could not verify manifest — image may still be available\n"
fi

echo ""
ok "Build and push complete!"
printf "  Image: ${CYAN}%s${NC}\n" "$FULL_IMAGE"
echo ""
printf "  Next: sign the image with one of:\n"
printf "    ${YELLOW}bash demos/demo2-smallstep/run.sh${NC}  (Smallstep CA path)\n"
printf "    ${YELLOW}bash demos/demo3-sigstore/run.sh${NC}   (Sigstore keyless path)\n"
echo ""
