#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Forceful reset of the demo environment (without tearing down
#              the underlying cluster).
# =============================================================================
# When `helm uninstall` leaves stuck pods, terminating namespaces, orphan
# Kyverno webhook configurations (which block ALL cluster-wide deletes),
# or PVCs with finalizers that never release, the cluster ends up in a state
# where `install.sh` cannot run again. This script forcefully resets everything
# created by the demo while leaving the underlying cluster (minikube or AKS)
# intact.
#
# Use this instead of `aks-down.sh` when you only want to re-run `install.sh`
# without paying AKS cluster creation time again.
#
# Steps:
#   1. Stop port-forwards (delegates to scripts/uninstall.sh logic).
#   2. Delete Kyverno ValidatingWebhookConfigurations and
#      MutatingWebhookConfigurations FIRST. Failure-policy=Fail webhooks
#      pointing at a service that no longer has endpoints will block every
#      pod/job/secret delete in the cluster.
#   3. `helm uninstall` the demo release with --no-hooks (skip post-delete
#      hooks that may try to call the missing Kyverno webhook).
#   4. Force-delete pods, jobs, deployments, replicasets, statefulsets in
#      each demo namespace (--grace-period=0 --force).
#   5. Patch out finalizers on PVCs so persistent volumes can release.
#   6. Delete demo CRDs that don't carry user data (Kyverno policy reports,
#      Sigstore TUF, etc.). Optional via PURGE_CRDS=true.
#   7. Wait for namespaces to fully terminate; patch out namespace finalizers
#      if they remain Terminating after the timeout.
#
# Environment variables:
#   RELEASE_NAME      Helm release name (default: devsecops-demo)
#   HELM_NAMESPACE    Helm release namespace (default: pki)
#   FORCE             true|false  Skip the interactive confirmation prompt.
#   PURGE_CRDS        true|false  Also delete Kyverno/Sigstore CRDs.
#                                  Default false (keep CRDs for faster
#                                  re-installs).
#   NS_WAIT_SECONDS   How long to wait for namespaces to terminate before
#                     patching out finalizers. Default 60.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RELEASE_NAME="${RELEASE_NAME:-devsecops-demo}"
HELM_NAMESPACE="${HELM_NAMESPACE:-pki}"
FORCE="${FORCE:-false}"
PURGE_CRDS="${PURGE_CRDS:-false}"
NS_WAIT_SECONDS="${NS_WAIT_SECONDS:-60}"

DEMO_NAMESPACES=(
  pki
  workload
  policy
  registry
  fulcio-system
  rekor-system
  tuf-system
  trillian-system
  ctlog-system
)

PID_FILE="/tmp/devsecops-pf.pids"

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

header() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }
info()   { printf "  ${YELLOW}%s${NC}\n" "$1"; }
ok()     { printf "  ${GREEN}[OK]${NC} %s\n" "$1"; }
warn()   { printf "  ${YELLOW}[WARN]${NC} %s\n" "$1"; }
step()   { printf "\n${YELLOW}▶ %s${NC}\n" "$1"; }

# Detect cluster (sets CLUSTER_KIND, etc.) — non-fatal if missing.
if [ -f "$SCRIPT_DIR/_cluster-detect.sh" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/_cluster-detect.sh" || true
fi

header "DevSecOps Demo — Forceful Cleanup"
info "Cluster context: $(kubectl config current-context 2>/dev/null || echo unknown)"
info "Release: $RELEASE_NAME (helm ns: $HELM_NAMESPACE)"
info "Demo namespaces: ${DEMO_NAMESPACES[*]}"
info "Purge CRDs: $PURGE_CRDS"

if [ "$FORCE" != "true" ]; then
  echo ""
  printf "  ${RED}This will forcefully delete all demo resources.${NC}\n"
  printf "  PersistentVolumeClaims and their data WILL be lost.\n"
  printf "  Continue? [y/N] "
  read -r ans
  if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
    info "Aborted."
    exit 0
  fi
fi

# =============================================================================
# 1. Stop port-forwards
# =============================================================================
header "Stopping port-forwards"
if [ -f "$PID_FILE" ]; then
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    if kill "$pid" 2>/dev/null; then
      info "Killed port-forward PID $pid"
    fi
  done < "$PID_FILE"
  rm -f "$PID_FILE"
  ok "Port-forwards stopped"
else
  info "No PID file at $PID_FILE — skipping"
fi
rm -f /tmp/pf-*.log 2>/dev/null || true

# =============================================================================
# 2. Delete Kyverno webhook configurations FIRST
# =============================================================================
# These point at devsecops-demo-kyverno-svc with failurePolicy=Fail. Once the
# Kyverno admission-controller pods are gone, ALL cluster-wide deletes start
# failing with "failed calling webhook ... no endpoints available for service
# devsecops-demo-kyverno-svc". Remove them before doing anything else.
header "Removing orphan Kyverno admission webhooks"
VWHCS=()
MWHCS=()
while IFS= read -r line; do [ -n "$line" ] && VWHCS+=("$line"); done < <(kubectl get validatingwebhookconfigurations -o name 2>/dev/null | grep -i kyverno || true)
while IFS= read -r line; do [ -n "$line" ] && MWHCS+=("$line"); done < <(kubectl get mutatingwebhookconfigurations   -o name 2>/dev/null | grep -i kyverno || true)
if [ ${#VWHCS[@]} -eq 0 ] && [ ${#MWHCS[@]} -eq 0 ]; then
  info "No Kyverno webhook configurations found"
else
  for w in "${VWHCS[@]:-}" "${MWHCS[@]:-}"; do
    [ -z "$w" ] && continue
    if kubectl delete "$w" --ignore-not-found --timeout=30s >/dev/null 2>&1; then
      ok "Deleted $w"
    else
      warn "Could not delete $w (continuing)"
    fi
  done
fi

# =============================================================================
# 3. Helm uninstall
# =============================================================================
header "Helm uninstall (--no-hooks)"
if command -v helm >/dev/null 2>&1; then
  if helm status "$RELEASE_NAME" -n "$HELM_NAMESPACE" >/dev/null 2>&1; then
    if helm uninstall "$RELEASE_NAME" -n "$HELM_NAMESPACE" --no-hooks --timeout 2m 2>&1 | tail -3; then
      ok "Helm release removed"
    else
      warn "helm uninstall reported errors (continuing with force cleanup)"
    fi
  else
    info "Helm release '$RELEASE_NAME' not found in namespace '$HELM_NAMESPACE'"
  fi
else
  warn "helm CLI not found — skipping helm uninstall"
fi

# =============================================================================
# 4. Force-delete workloads in demo namespaces
# =============================================================================
header "Force-deleting demo workloads"
for ns in "${DEMO_NAMESPACES[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  info "Cleaning namespace: $ns"
  kubectl delete jobs,deployments,replicasets,statefulsets,daemonsets,cronjobs \
    --all -n "$ns" --grace-period=0 --force --ignore-not-found 2>&1 \
    | grep -v "^Warning: Immediate" | sed 's/^/    /' | head -10 || true
  kubectl delete pods --all -n "$ns" --grace-period=0 --force --ignore-not-found 2>&1 \
    | grep -v "^Warning: Immediate" | sed 's/^/    /' | head -10 || true
done
ok "Workload deletion submitted"

# =============================================================================
# 5. Release PVC finalizers
# =============================================================================
header "Releasing PVC finalizers"
for ns in "${DEMO_NAMESPACES[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  PVCS=()
  while IFS= read -r line; do [ -n "$line" ] && PVCS+=("$line"); done \
    < <(kubectl get pvc -n "$ns" -o name 2>/dev/null || true)
  for pvc in "${PVCS[@]:-}"; do
    [ -z "$pvc" ] && continue
    kubectl patch "$pvc" -n "$ns" --type=merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
      && info "Patched $ns/$pvc" || true
    kubectl delete "$pvc" -n "$ns" --grace-period=0 --force --ignore-not-found \
      >/dev/null 2>&1 || true
  done
done
ok "PVC finalizers released"

# =============================================================================
# 6. (Optional) Purge demo CRDs
# =============================================================================
if [ "$PURGE_CRDS" = "true" ]; then
  header "Purging demo CRDs (PURGE_CRDS=true)"
  CRD_PATTERNS=(
    "kyverno.io"
    "wgpolicyk8s.io"
    "reports.kyverno.io"
    "rekor.sigstore.dev"
    "fulcio.sigstore.dev"
    "trillian.sigstore.dev"
    "policies.kyverno.io"
  )
  for pat in "${CRD_PATTERNS[@]}"; do
    CRDS=()
    while IFS= read -r line; do [ -n "$line" ] && CRDS+=("$line"); done \
      < <(kubectl get crds -o name 2>/dev/null | grep -E "$pat" || true)
    for crd in "${CRDS[@]:-}"; do
      [ -z "$crd" ] && continue
      kubectl get "$crd" -A -o name 2>/dev/null | while read -r cr; do
        kubectl patch "$cr" --type=merge -p '{"metadata":{"finalizers":null}}' \
          >/dev/null 2>&1 || true
      done
      kubectl delete "$crd" --ignore-not-found --timeout=30s >/dev/null 2>&1 \
        && ok "Deleted $crd" \
        || warn "Could not delete $crd"
    done
  done
else
  info "Skipping CRD purge (set PURGE_CRDS=true to also drop Kyverno/Sigstore CRDs)"
fi

# =============================================================================
# 7. Wait for namespaces, force-finalize stragglers
# =============================================================================
header "Waiting for namespaces to terminate (up to ${NS_WAIT_SECONDS}s)"
end=$((SECONDS + NS_WAIT_SECONDS))
while [ $SECONDS -lt $end ]; do
  remaining=()
  for ns in "${DEMO_NAMESPACES[@]}"; do
    kubectl get ns "$ns" >/dev/null 2>&1 && remaining+=("$ns")
  done
  if [ ${#remaining[@]} -eq 0 ]; then
    ok "All demo namespaces terminated"
    break
  fi
  printf "  Still terminating: %s\n" "${remaining[*]}"
  sleep 5
done

# Force-finalize anything still stuck. This patches metadata.finalizers to []
# via the namespace's /finalize subresource — the last-resort escape hatch.
STUCK=()
for ns in "${DEMO_NAMESPACES[@]}"; do
  status=$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$status" = "Terminating" ] && STUCK+=("$ns")
done
if [ ${#STUCK[@]} -gt 0 ]; then
  warn "Forcibly clearing finalizers on stuck namespaces: ${STUCK[*]}"
  for ns in "${STUCK[@]}"; do
    # Find any remaining resources in the namespace (best-effort listing) and
    # drop their finalizers so the namespace controller can complete.
    kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null \
      | xargs -n1 -P 4 kubectl get -n "$ns" -o name --ignore-not-found 2>/dev/null \
      | while read -r obj; do
          [ -z "$obj" ] && continue
          kubectl patch "$obj" -n "$ns" --type=merge \
            -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
          kubectl delete "$obj" -n "$ns" --grace-period=0 --force \
            --ignore-not-found >/dev/null 2>&1 || true
        done
    # Last resort: clear finalizers on the namespace itself via the
    # /finalize subresource. Requires cluster-admin.
    kubectl get ns "$ns" -o json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
      | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null 2>&1 \
      && ok "Force-finalized $ns" \
      || warn "Could not force-finalize $ns"
  done
fi

# =============================================================================
# 8. Final summary
# =============================================================================
header "Cleanup summary"
LEFT=()
for ns in "${DEMO_NAMESPACES[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 && LEFT+=("$ns")
done
if [ ${#LEFT[@]} -eq 0 ]; then
  ok "All demo namespaces removed"
else
  warn "Still present: ${LEFT[*]} — they may finish terminating shortly"
fi

if helm status "$RELEASE_NAME" -n "$HELM_NAMESPACE" >/dev/null 2>&1; then
  warn "Helm release '$RELEASE_NAME' is still present in '$HELM_NAMESPACE'"
else
  ok "Helm release '$RELEASE_NAME' is gone"
fi

echo ""
ok "Cleanup complete. You can now re-run:"
case "${CLUSTER_KIND:-unknown}" in
  aks)
    printf "    ${CYAN}VALUES_FILE=chart/values-aks.local.yaml bash scripts/install.sh${NC}\n"
    ;;
  minikube)
    printf "    ${CYAN}bash scripts/install.sh${NC}\n"
    ;;
  *)
    printf "    ${CYAN}bash scripts/install.sh${NC}\n"
    ;;
esac
echo ""
