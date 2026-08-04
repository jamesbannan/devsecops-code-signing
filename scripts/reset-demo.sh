#!/usr/bin/env bash
# =============================================================================
# reset-demo.sh — Reset the demo workloads without tearing down core PKI
# =============================================================================
# Sister script to cleanup.sh. Where cleanup.sh nukes the entire demo
# environment (pki, fulcio, rekor, tuf, trillian, ctlog, registry, policy,
# workload), reset-demo.sh leaves the core architecture in place and only
# resets the bits that change between demo runs:
#
#   1. All Jobs in the `workload` namespace (signing-job-*, verification-job,
#      and the failure-jobs). Their pods cascade away.
#   2. Any orphan pods in `workload`.
#   3. (optional, --purge-images) Demo images tagged in the registry.
#   4. (default on, --no-redeploy to skip) Re-run `helm upgrade --install`
#      so the workload Jobs are reapplied and execute fresh.
#
# Use this between demo sessions when you don't want to wait for
# install.sh to redeploy step-ca, Trillian, MySQL, Fulcio, Rekor, etc.
#
# Environment variables:
#   RELEASE_NAME      Helm release name      (default: devsecops-demo)
#   HELM_NAMESPACE    Helm release namespace (default: pki)
#   FORCE             true|false   Skip the confirmation prompt.
#
# Flags:
#   --purge-images    Also delete demo/* images from the local registry.
#   --no-redeploy     Skip the helm upgrade at the end.
#   -y, --force       Skip confirmation prompt.
#   -h, --help        Show this help.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART_DIR="$REPO_ROOT/chart"

RELEASE_NAME="${RELEASE_NAME:-devsecops-demo}"
HELM_NAMESPACE="${HELM_NAMESPACE:-pki}"
FORCE="${FORCE:-false}"
PID_FILE="/tmp/devsecops-pf.pids"
PURGE_IMAGES=false
REDEPLOY=true

for arg in "$@"; do
  case "$arg" in
    --purge-images) PURGE_IMAGES=true ;;
    --no-redeploy)  REDEPLOY=false ;;
    -y|--force)     FORCE=true ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf "Unknown argument: %s (use -h for help)\n" "$arg" >&2; exit 2 ;;
  esac
done

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

header() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
info()   { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()     { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
warn()   { printf "  ${YELLOW}[WARN]${NC} %s\n" "$1"; }

# Detect cluster (sets CLUSTER_KIND, REGISTRY, etc.) — non-fatal.
if [ -f "$SCRIPT_DIR/_cluster-detect.sh" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/_cluster-detect.sh" || true
fi

header "DevSecOps Demo — Soft Reset"
info "Cluster context: $(kubectl config current-context 2>/dev/null || echo unknown)"
info "Cluster kind:    ${CLUSTER_KIND:-unknown}"
info "Release:         $RELEASE_NAME (helm ns: $HELM_NAMESPACE)"
info "Purge images:    $PURGE_IMAGES"
info "Redeploy jobs:   $REDEPLOY"

if [ "$FORCE" != "true" ]; then
  echo ""
  printf "  ${RED}This will delete all Jobs and pods in the 'workload' namespace.${NC}\n"
  printf "  Core PKI components (pki, fulcio, rekor, tuf, trillian, ctlog, registry, policy)\n"
  printf "  will be left untouched.\n"
  printf "  Continue? [y/N] "
  read -r ans
  # Lowercase without bash 4 `${ans,,}` — macOS ships bash 3.2 (/usr/bin/env bash),
  # where `${ans,,}` is a "bad substitution".
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  if [ "$ans" != "y" ] && [ "$ans" != "yes" ]; then
    info "Aborted."
    exit 0
  fi
fi

# =============================================================================
# 1. Delete Jobs in workload namespace (cascades to pods)
# =============================================================================
header "Deleting Jobs in workload namespace"
if kubectl get ns workload &>/dev/null; then
  JOBS=$(kubectl get jobs -n workload -o name 2>/dev/null | wc -l | tr -d ' ')
  if [ "${JOBS:-0}" -gt 0 ]; then
    kubectl delete jobs --all -n workload --ignore-not-found --wait=false 2>&1 \
      | sed 's/^/    /' | head -20 || true
    ok "Deleted $JOBS Job(s)"
  else
    info "No Jobs to delete"
  fi
else
  warn "'workload' namespace not found — nothing to reset"
fi

# =============================================================================
# 2. Sweep leftover pods (orphans, finalizer-stuck completed pods)
# =============================================================================
header "Sweeping leftover pods in workload namespace"
if kubectl get ns workload &>/dev/null; then
  PODS=$(kubectl get pods -n workload -o name 2>/dev/null | wc -l | tr -d ' ')
  if [ "${PODS:-0}" -gt 0 ]; then
    # Drop finalizers first so --force can actually delete.
    kubectl get pods -n workload -o name 2>/dev/null | while read -r p; do
      [ -z "$p" ] && continue
      kubectl patch "$p" -n workload --type=merge \
        -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done
    kubectl delete pods --all -n workload --grace-period=0 --force \
      --ignore-not-found --wait=false 2>&1 \
      | grep -v "^Warning: Immediate" | sed 's/^/    /' | head -20 || true
    ok "Deleted $PODS pod(s)"
  else
    info "No leftover pods"
  fi
fi

# =============================================================================
# 3. (optional) Purge demo images from the registry
# =============================================================================
if [ "$PURGE_IMAGES" = "true" ]; then
  header "Purging demo images from registry"
  case "${CLUSTER_KIND:-}" in
    aks)
      if [ -n "${ACR_NAME:-}" ] && command -v az >/dev/null 2>&1; then
        for repo in demo/app demo/app-tampered demo/app-unsigned; do
          if az acr repository show -n "$ACR_NAME" --repository "$repo" >/dev/null 2>&1; then
            az acr repository delete -n "$ACR_NAME" --repository "$repo" --yes >/dev/null 2>&1 \
              && ok "Deleted $repo from ACR" \
              || warn "Could not delete $repo from ACR"
          else
            info "$repo not present in ACR"
          fi
        done
      else
        warn "az CLI or ACR_NAME unavailable — skipping image purge"
      fi
      ;;
    minikube|*)
      # In-cluster registry has no admin API. Restart the registry pod
      # to drop the in-memory storage layer (registry uses emptyDir by
      # default in this chart).
      if kubectl get deploy -n registry registry >/dev/null 2>&1; then
        kubectl rollout restart deploy/registry -n registry >/dev/null 2>&1 \
          && ok "Restarted in-cluster registry (storage flushed)" \
          || warn "Could not restart in-cluster registry"
      else
        warn "registry deployment not found — skipping image purge"
      fi
      ;;
  esac
fi

# =============================================================================
# 4. Redeploy workload Jobs via helm upgrade
# =============================================================================
if [ "$REDEPLOY" = "true" ]; then
  header "Redeploying workload Jobs (helm upgrade)"
  if ! command -v helm >/dev/null 2>&1; then
    warn "helm not installed — skipping redeploy"
  elif ! helm status "$RELEASE_NAME" -n "$HELM_NAMESPACE" >/dev/null 2>&1; then
    warn "Release '$RELEASE_NAME' not found in '$HELM_NAMESPACE' — run install.sh first"
  else
    # --force-recreate isn't a thing; instead we rely on `helm upgrade` seeing
    # the deleted Jobs as drift and reapplying them. --reuse-values keeps
    # whatever values the original install was performed with (incl. the AKS
    # local override file via -f).
    #
    # --force-conflicts is required because the demos `kubectl patch` the Kyverno
    # `require-image-signature` ClusterPolicy (demo5 flips validationFailureAction
    # to Enforce and mutateDigest to true). That creates a `kubectl-patch`
    # server-side-apply field manager owning `.spec.rules`, which collides with
    # Helm 4's server-side apply ("conflict with kubectl-patch ... .spec.rules").
    # Forcing conflicts lets Helm reclaim ownership and reset the policy to the
    # chart defaults — exactly what a reset should do.
    if helm upgrade "$RELEASE_NAME" "$CHART_DIR" \
         -n "$HELM_NAMESPACE" --reuse-values --force-conflicts --timeout 5m 2>&1 | tail -5; then
      ok "Workload Jobs reapplied"

      # The helm upgrade re-runs the step-ca codesigning-config hook
      # (post-install,post-upgrade), which `kubectl rollout restart`s the
      # step-ca StatefulSet to pick up the code-signing EKU config. That
      # silently kills the `kubectl port-forward` to localhost:39000, so the
      # next demo that talks to step-ca fails with "connection refused".
      # Re-establish the local port-forwards if they were in use.
      if [ -f "$PID_FILE" ]; then
        header "Re-establishing port-forwards (helm upgrade restarted step-ca)"
        if bash "$SCRIPT_DIR/port-forward.sh"; then
          ok "Port-forwards re-established"
        else
          warn "Could not re-establish port-forwards — run 'bash scripts/resume.sh'"
        fi
      else
        info "Note: the helm upgrade restarted step-ca. If you use port-forwards,"
        info "(re)start them with: bash scripts/port-forward.sh   (or resume.sh)"
      fi
    else
      warn "helm upgrade reported errors — check 'helm status $RELEASE_NAME -n $HELM_NAMESPACE'"
    fi
  fi
else
  info "Skipping redeploy (--no-redeploy)"
fi

header "Soft reset complete"
info "Inspect with: kubectl get pods -n workload"
info "Run demos again from demos/ directory."
