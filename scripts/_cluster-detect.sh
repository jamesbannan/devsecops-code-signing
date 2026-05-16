#!/usr/bin/env bash
# =============================================================================
# _cluster-detect.sh — Source me, don't execute me.
# =============================================================================
# Detects whether the current kubectl context points at:
#   - minikube   → CLUSTER_KIND=minikube
#   - AKS        → CLUSTER_KIND=aks
#   - other      → CLUSTER_KIND=other (best effort, scripts may warn and continue)
#
# When AKS is detected and the Terraform stack in infra/aks/ has live state,
# this helper also exports:
#   ACR_LOGIN_SERVER, ACR_NAME, AKS_OIDC_ISSUER_URL, AKS_RG, AKS_CLUSTER
#
# Output variables (always set after sourcing):
#   CLUSTER_KIND          minikube | aks | other
#   REGISTRY              host-side push endpoint
#                         (minikube → localhost:30500 via port-forward, AKS → ACR)
#   CLUSTER_REGISTRY      in-cluster pull endpoint used by Kubernetes
#                         (minikube → registry.registry.svc:5000, AKS → ACR)
#
# Usage:
#   source "$(dirname "$0")/_cluster-detect.sh"
#   case "$CLUSTER_KIND" in ...) ;; esac
# =============================================================================

# shellcheck disable=SC2034  # variables are consumed by sourcing scripts

_cd_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_cd_infra_dir="${_cd_script_dir}/../infra/aks"

CLUSTER_KIND="other"
_cd_registry_was_set="${REGISTRY+set}"
_cd_cluster_registry_was_set="${CLUSTER_REGISTRY+set}"
REGISTRY="${REGISTRY:-localhost:30500}"
CLUSTER_REGISTRY="${CLUSTER_REGISTRY:-registry.registry.svc:5000}"
ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER:-}"
ACR_NAME="${ACR_NAME:-}"
AKS_OIDC_ISSUER_URL="${AKS_OIDC_ISSUER_URL:-}"
AKS_RG="${AKS_RG:-}"
AKS_CLUSTER="${AKS_CLUSTER:-}"

_cd_ctx=""
if command -v kubectl >/dev/null 2>&1; then
  _cd_ctx="$(kubectl config current-context 2>/dev/null || true)"
fi

if [ -n "$_cd_ctx" ]; then
  if [[ "$_cd_ctx" =~ ^minikube ]]; then
    CLUSTER_KIND="minikube"
  else
    _cd_provider="$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)"
    if [[ "$_cd_provider" == azure://* ]]; then
      CLUSTER_KIND="aks"
    fi
  fi
fi

if [ "$CLUSTER_KIND" = "aks" ]; then
  if [ -f "${_cd_infra_dir}/terraform.tfstate" ] && command -v terraform >/dev/null 2>&1; then
    _cd_tf_out() { terraform -chdir="${_cd_infra_dir}" output -raw "$1" 2>/dev/null || true; }
    ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER:-$(_cd_tf_out acr_login_server)}"
    ACR_NAME="${ACR_NAME:-$(_cd_tf_out acr_name)}"
    AKS_OIDC_ISSUER_URL="${AKS_OIDC_ISSUER_URL:-$(_cd_tf_out oidc_issuer_url)}"
    AKS_RG="${AKS_RG:-$(_cd_tf_out resource_group_name)}"
    AKS_CLUSTER="${AKS_CLUSTER:-$(_cd_tf_out cluster_name)}"
    unset -f _cd_tf_out
  fi

  if [ -n "$ACR_LOGIN_SERVER" ]; then
    [ -z "$_cd_registry_was_set" ] && REGISTRY="$ACR_LOGIN_SERVER"
    [ -z "$_cd_cluster_registry_was_set" ] && CLUSTER_REGISTRY="$ACR_LOGIN_SERVER"
  fi
fi

unset _cd_script_dir _cd_infra_dir _cd_ctx _cd_provider _cd_registry_was_set _cd_cluster_registry_was_set
