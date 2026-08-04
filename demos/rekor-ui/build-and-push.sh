#!/usr/bin/env bash
# =============================================================================
# build-and-push.sh — Build and push the Rekor Search UI image
# =============================================================================
# Builds the self-contained Rekor Search UI image (Next.js static export +
# nginx same-origin proxy) and pushes it to the demo registry:
#   minikube → localhost:30500/demo/rekor-ui:latest  (via in-cluster registry)
#   AKS      → <acr-login-server>/demo/rekor-ui:latest
#
# This mirrors demos/demo-app/build-and-push.sh — see that script's header for
# the build-tool selection rationale (minikube image build vs podman vs docker).
#
# Usage:
#   bash demos/rekor-ui/build-and-push.sh
#   IMAGE_TAG=v1.2.3 bash demos/rekor-ui/build-and-push.sh
#   REKOR_UI_REF=<git-sha> bash demos/rekor-ui/build-and-push.sh   # bump upstream
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

IMAGE_NAME="${IMAGE_NAME:-demo/rekor-ui}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="$REGISTRY/$IMAGE_NAME:$IMAGE_TAG"

# Pinned upstream ref baked into the static export (overridable).
REKOR_UI_REF="${REKOR_UI_REF:-4814ed26cf8142173eebc58ed1602e669bf548a2}"

# AKS nodes run amd64 by default; force linux/amd64 unless overridden.
if [ "$CLUSTER_KIND" = "aks" ]; then
  TARGET_PLATFORM="${TARGET_PLATFORM:-linux/amd64}"
else
  TARGET_PLATFORM="${TARGET_PLATFORM:-}"
fi

header() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
info()   { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()     { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
cmd()    { printf "  ${YELLOW}\$ %s${NC}\n" "$1"; }

header "Building rekor-ui"
info "Cluster:    $CLUSTER_KIND"
info "Image:      $FULL_IMAGE"
info "Upstream:   sigstore/rekor-search-ui @ $REKOR_UI_REF"
[ -n "$TARGET_PLATFORM" ] && info "Platform:   $TARGET_PLATFORM"

# --- Detect build tool ---
BUILD_TOOL=""
if [ "$CLUSTER_KIND" = "aks" ]; then
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
    cmd "minikube image build -t $FULL_IMAGE --build-opt opt=build-arg:REKOR_UI_REF=$REKOR_UI_REF $SCRIPT_DIR"
    minikube image build \
      -t "$FULL_IMAGE" \
      --build-opt "opt=build-arg:REKOR_UI_REF=$REKOR_UI_REF" \
      "$SCRIPT_DIR"
    ;;
  podman)
    cmd "podman build ${TARGET_PLATFORM:+--platform $TARGET_PLATFORM }-t $FULL_IMAGE $SCRIPT_DIR"
    podman build \
      --tls-verify=false \
      ${TARGET_PLATFORM:+--platform "$TARGET_PLATFORM"} \
      --build-arg "REKOR_UI_REF=$REKOR_UI_REF" \
      --tag "$FULL_IMAGE" \
      "$SCRIPT_DIR"
    ;;
  docker)
    cmd "docker build ${TARGET_PLATFORM:+--platform $TARGET_PLATFORM }-t $FULL_IMAGE $SCRIPT_DIR"
    docker build \
      ${TARGET_PLATFORM:+--platform "$TARGET_PLATFORM"} \
      --build-arg "REKOR_UI_REF=$REKOR_UI_REF" \
      --tag "$FULL_IMAGE" \
      "$SCRIPT_DIR"
    ;;
esac

ok "Image built: $FULL_IMAGE"

# --- Authenticate / verify registry connectivity ---
if [ "$CLUSTER_KIND" = "aks" ]; then
  header "Authenticating to Azure Container Registry"
  if [ -z "${ACR_NAME:-}" ]; then
    printf "  ${RED}[ERROR]${NC} ACR_NAME not set. Did 'scripts/aks-up.sh' run successfully?\n"
    exit 1
  fi
  cmd "az acr login -n $ACR_NAME"
  az acr login -n "$ACR_NAME" --only-show-errors
  ok "Authenticated to $REGISTRY"
elif [ "$BUILD_TOOL" = "minikube" ]; then
  # The minikube path pushes into the node's containerd and then to the registry
  # ClusterIP via `ctr` (see the push step below). It does NOT use the
  # localhost:30500 host port-forward, so there is nothing host-side to verify
  # here. Requiring the port-forward would wrongly fail this script when it is
  # run by install.sh *before* port-forwards are started — which would skip the
  # push entirely (the image would only ever exist in the node's containerd).
  info "minikube build — image is pushed via the registry ClusterIP (no host port-forward needed)"
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
  case "$BUILD_TOOL" in
    docker) cmd "docker push $FULL_IMAGE"; docker push "$FULL_IMAGE" ;;
    podman) cmd "podman push $FULL_IMAGE"; podman push "$FULL_IMAGE" ;;
  esac
else
  case "$BUILD_TOOL" in
    minikube)
      # minikube image build stores the image in the node's containerd. Push to
      # the in-cluster registry via ctr using the registry ClusterIP, since
      # buildkit's resolver can't reach cluster service names.
      REGISTRY_IP=$(kubectl get svc registry -n registry -o jsonpath='{.spec.clusterIP}')
      PUSH_REF="${REGISTRY_IP}:5000/$IMAGE_NAME:$IMAGE_TAG"
      info "Tagging for in-cluster push: $PUSH_REF"
      minikube ssh -- "sudo ctr -n k8s.io images tag '$FULL_IMAGE' '$PUSH_REF'" 2>/dev/null || true
      cmd "minikube ssh -- sudo ctr -n k8s.io images push --plain-http $PUSH_REF"
      minikube ssh -- "sudo ctr -n k8s.io images push --plain-http '$PUSH_REF'" 2>&1
      ;;
    podman) cmd "podman push --tls-verify=false $FULL_IMAGE"; podman push --tls-verify=false "$FULL_IMAGE" ;;
    docker) cmd "docker push $FULL_IMAGE"; docker push "$FULL_IMAGE" ;;
  esac
fi

ok "Image pushed: $FULL_IMAGE"

# --- Roll the deployment if it already exists ---
if kubectl get deploy rekor-ui -n registry &>/dev/null; then
  header "Restarting the rekor-ui deployment"
  cmd "kubectl rollout restart deploy/rekor-ui -n registry"
  kubectl rollout restart deploy/rekor-ui -n registry
  ok "Rollout triggered — new pod will pull the freshly pushed image"
fi

echo ""
ok "rekor-ui build and push complete!"
printf "  Image: ${CYAN}%s${NC}\n" "$FULL_IMAGE"
echo ""
if [ "$CLUSTER_KIND" != "aks" ]; then
  printf "  Open the UI (after port-forwards are up): ${YELLOW}http://localhost:30900${NC}\n"
  printf "  Start/refresh forwards with: ${YELLOW}bash scripts/port-forward.sh${NC}\n"
else
  printf "  Port-forward the UI: ${YELLOW}kubectl port-forward svc/rekor-ui 30900:8080 -n registry${NC}\n"
fi
echo ""
