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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Source cluster detection — sets CLUSTER_KIND, REGISTRY, CLUSTER_REGISTRY,
# ACR_LOGIN_SERVER, ACR_NAME. Honours pre-set REGISTRY env var.
# shellcheck source=../../scripts/_cluster-detect.sh
source "$REPO_ROOT/scripts/_cluster-detect.sh"

IMAGE_NAME="${IMAGE_NAME:-demo/app}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="$REGISTRY/$IMAGE_NAME:$IMAGE_TAG"

GIT_SHA=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# AKS nodes run on amd64 by default; macOS/M-series developers build arm64
# images unless told otherwise, which yields exec-format errors and
# CrashLoopBackOff after admission. Force linux/amd64 when targeting AKS.
# Override via TARGET_PLATFORM=linux/arm64 if you have arm64 node pools.
if [ "$CLUSTER_KIND" = "aks" ]; then
  TARGET_PLATFORM="${TARGET_PLATFORM:-linux/amd64}"
else
  TARGET_PLATFORM="${TARGET_PLATFORM:-}"
fi

header() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
info()   { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()     { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
cmd()    { printf "  ${YELLOW}\$ %s${NC}\n" "$1"; }

header "Building demo-app"
info "Cluster:    $CLUSTER_KIND"
info "Image:      $FULL_IMAGE"
info "Git SHA:    $GIT_SHA"
info "Build time: $BUILD_TIME"
[ -n "$TARGET_PLATFORM" ] && info "Platform:   $TARGET_PLATFORM"

# --- Detect build tool ---
BUILD_TOOL=""
if [ "$CLUSTER_KIND" = "aks" ]; then
  # On AKS we must push to ACR via docker/podman — minikube is irrelevant.
  if command -v docker &>/dev/null; then
    BUILD_TOOL="docker"
  elif command -v podman &>/dev/null; then
    BUILD_TOOL="podman"
  else
    printf "  ${RED}[ERROR]${NC} No container build tool found (docker or podman) for ACR push.\n"
    exit 1
  fi
elif command -v minikube &>/dev/null && minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
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
    cmd "podman build ${TARGET_PLATFORM:+--platform $TARGET_PLATFORM }-t $FULL_IMAGE $SCRIPT_DIR"
    podman build \
      --tls-verify=false \
      ${TARGET_PLATFORM:+--platform "$TARGET_PLATFORM"} \
      --build-arg "GIT_SHA=$GIT_SHA" \
      --build-arg "BUILD_TIME=$BUILD_TIME" \
      --tag "$FULL_IMAGE" \
      "$SCRIPT_DIR"
    ;;
  docker)
    cmd "docker build ${TARGET_PLATFORM:+--platform $TARGET_PLATFORM }-t $FULL_IMAGE $SCRIPT_DIR"
    docker build \
      ${TARGET_PLATFORM:+--platform "$TARGET_PLATFORM"} \
      --build-arg "GIT_SHA=$GIT_SHA" \
      --build-arg "BUILD_TIME=$BUILD_TIME" \
      --tag "$FULL_IMAGE" \
      "$SCRIPT_DIR"
    ;;
esac

ok "Image built: $FULL_IMAGE"

# --- Verify local registry is reachable / authenticate ---
if [ "$CLUSTER_KIND" = "aks" ]; then
  header "Authenticating to Azure Container Registry"
  if [ -z "${ACR_NAME:-}" ]; then
    printf "  ${RED}[ERROR]${NC} ACR_NAME not set. Did 'scripts/aks-up.sh' run successfully?\n"
    exit 1
  fi
  cmd "az acr login -n $ACR_NAME"
  az acr login -n "$ACR_NAME" --only-show-errors
  ok "Authenticated to $REGISTRY"
else
  header "Checking registry connectivity"
  if ! curl -sf "http://$REGISTRY/v2/" -o /dev/null; then
    printf "  ${RED}[ERROR]${NC} Registry at %s is not reachable.\n" "$REGISTRY"
    echo "  Ensure port-forwards are running: bash scripts/port-forward.sh"
    exit 1
  fi
  ok "Registry reachable at $REGISTRY"
fi

# --- Push ---
header "Pushing image to registry"

if [ "$CLUSTER_KIND" = "aks" ]; then
  # Direct push to ACR via docker/podman (already authenticated via az acr login)
  case "$BUILD_TOOL" in
    docker)
      cmd "docker push $FULL_IMAGE"
      docker push "$FULL_IMAGE"
      ;;
    podman)
      cmd "podman push $FULL_IMAGE"
      podman push "$FULL_IMAGE"
      ;;
  esac
else
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
fi

ok "Image pushed: $FULL_IMAGE"

# --- Verify the push by pulling the manifest ---
header "Verifying push"
DIGEST=""
TAG_LIST=""
if [ "$CLUSTER_KIND" = "aks" ]; then
  cmd "az acr repository show-manifests -n $ACR_NAME --repository $IMAGE_NAME"
  DIGEST=$(az acr repository show-manifests -n "$ACR_NAME" --repository "$IMAGE_NAME" \
    --query "[?tags && contains(tags, '$IMAGE_TAG')].digest | [0]" -o tsv 2>/dev/null || echo "")
  TAG_LIST=$(az acr repository show-tags -n "$ACR_NAME" --repository "$IMAGE_NAME" \
    -o tsv 2>/dev/null | paste -sd, - || echo "")
else
  cmd "curl -sf http://$REGISTRY/v2/$IMAGE_NAME/manifests/$IMAGE_TAG | jq .config.digest"
  MANIFEST_JSON=$(curl -sf \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "http://$REGISTRY/v2/$IMAGE_NAME/manifests/$IMAGE_TAG" 2>/dev/null || echo "")
  if [ -n "$MANIFEST_JSON" ]; then
    DIGEST=$(printf '%s' "$MANIFEST_JSON" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('config',{}).get('digest',''))" 2>/dev/null || echo "")
  fi
  TAG_LIST=$(curl -sf "http://$REGISTRY/v2/$IMAGE_NAME/tags/list" 2>/dev/null | \
    python3 -c "import sys,json; print(','.join(json.load(sys.stdin).get('tags',[])))" 2>/dev/null || echo "")
fi

if [ -n "$DIGEST" ]; then
  ok "Registry manifest reachable: $DIGEST"
else
  printf "  ${YELLOW}[WARN]${NC} Could not fetch manifest from the registry. The image\n"
  printf "         may still be present — try the verification commands below.\n"
fi
if [ -n "$TAG_LIST" ]; then
  ok "Tags in repository '$IMAGE_NAME': $TAG_LIST"
fi

# =============================================================================
# Verification cheat-sheet — printed every run for live troubleshooting
# =============================================================================
header "How to verify"
echo ""
printf "  ${CYAN}1. List tags in the repository${NC}\n"
if [ "$CLUSTER_KIND" = "aks" ]; then
  printf "       ${YELLOW}az acr repository show-tags -n %s --repository %s -o table${NC}\n" \
    "$ACR_NAME" "$IMAGE_NAME"
  printf "       ${YELLOW}az acr repository list      -n %s -o table${NC}\n" "$ACR_NAME"
else
  printf "       ${YELLOW}curl -s http://%s/v2/%s/tags/list | jq${NC}\n" "$REGISTRY" "$IMAGE_NAME"
  printf "       ${YELLOW}curl -s http://%s/v2/_catalog | jq${NC}\n" "$REGISTRY"
fi

echo ""
printf "  ${CYAN}2. Inspect the manifest / digest${NC}\n"
if [ "$CLUSTER_KIND" = "aks" ]; then
  printf "       ${YELLOW}az acr manifest show -r %s -n %s:%s${NC}\n" \
    "$ACR_NAME" "$IMAGE_NAME" "$IMAGE_TAG"
  printf "       ${YELLOW}az acr repository show -n %s --image %s:%s${NC}\n" \
    "$ACR_NAME" "$IMAGE_NAME" "$IMAGE_TAG"
else
  printf "       ${YELLOW}curl -s -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \\\\\n"
  printf "            http://%s/v2/%s/manifests/%s | jq${NC}\n" \
    "$REGISTRY" "$IMAGE_NAME" "$IMAGE_TAG"
fi

echo ""
printf "  ${CYAN}3. Pull the image (any client)${NC}\n"
printf "       ${YELLOW}docker pull %s${NC}      ${CYAN}# or:${NC} crane manifest %s\n" \
  "$FULL_IMAGE" "$FULL_IMAGE"

echo ""
printf "  ${CYAN}4. Confirm Kubernetes can pull / run it${NC}\n"
printf "       ${YELLOW}kubectl run demo-pull-test --rm -it --restart=Never \\\\\n"
printf "         --image=%s -- /demo-app --version${NC}\n" "$FULL_IMAGE"

echo ""
printf "  ${CYAN}5. Inspect with cosign (no signature yet — shows OCI tree only)${NC}\n"
if [ "$CLUSTER_KIND" = "aks" ]; then
  printf "       ${YELLOW}cosign tree %s${NC}\n" "$FULL_IMAGE"
else
  printf "       ${YELLOW}cosign tree --allow-insecure-registry %s${NC}\n" "$FULL_IMAGE"
fi

echo ""
printf "  ${CYAN}6. Visual / UI checks${NC}\n"
if [ "$CLUSTER_KIND" = "aks" ]; then
  printf "       Azure Portal → Container registries → ${YELLOW}%s${NC} → Repositories → ${YELLOW}%s${NC}\n" \
    "$ACR_NAME" "$IMAGE_NAME"
  printf "       (You'll see the tag '%s', digest, size, last-updated timestamp.)\n" "$IMAGE_TAG"
else
  printf "       Browser → ${YELLOW}http://%s/v2/_catalog${NC}\n" "$REGISTRY"
  printf "       Browser → ${YELLOW}http://%s/v2/%s/tags/list${NC}\n" "$REGISTRY" "$IMAGE_NAME"
  printf "       minikube dashboard → Workloads → Pods → 'registry' (logs show the PUT)\n"
fi

echo ""
ok "Build and push complete!"
printf "  Image:  ${CYAN}%s${NC}\n" "$FULL_IMAGE"
if [ -n "$DIGEST" ]; then
  printf "  Digest: ${CYAN}%s${NC}\n" "$DIGEST"
fi
echo ""
printf "  Next: run the demos in order (full narrative):\n"
printf "    ${YELLOW}bash demos/demo1-before/run.sh${NC}       (the painful baseline — manual GPG)\n"
printf "    ${YELLOW}bash demos/demo2-smallstep/run.sh${NC}    (Smallstep CA — signs this image)\n"
printf "    ${YELLOW}bash demos/demo3-sigstore/run.sh${NC}     (Sigstore keyless — signs this image)\n"
printf "    ${YELLOW}bash demos/demo4-cicd/run.sh${NC}         (CI/CD pipeline simulation)\n"
printf "    ${YELLOW}bash demos/demo5-verification/run.sh${NC} (Kyverno policy gate)\n"
printf "    ${YELLOW}bash demos/demo6-audit/run.sh${NC}        (attestation + audit trail)\n"
echo ""
printf "  Or jump straight to a signing demo: ${YELLOW}demo2-smallstep${NC} or ${YELLOW}demo3-sigstore${NC}.\n"
echo ""
