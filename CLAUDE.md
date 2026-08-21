# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`jamesbannan/devsecops-code-signing` is a complete, self-contained DevSecOps code-signing
demo backing the conference talk "Zero-Friction DevSecOps: Automated Code Signing Done
Right" (BSides Melbourne 2026 · AppSec Australia · KCD Melbourne 2026). A single Helm
chart deploys step-ca, Sigstore (Fulcio +
Rekor + TUF + Trillian via the `scaffold` chart), an in-cluster Docker Registry v2, and
Kyverno policy enforcement. Six demo scripts walk through GPG → Smallstep CA → Sigstore
keyless → CI/CD → policy enforcement → audit.

The same chart and demo scripts run on **local minikube** and **Azure Kubernetes Service**.
AKS provisioning is automated via a Terraform stack in `infra/aks/` (RG + ACR + UAMI +
AKS with workload identity + OIDC).

## Repository Layout

- `chart/` — umbrella Helm chart; `values.yaml` (minikube), `values-aks.yaml` (template;
  `values-aks.local.yaml` is rendered by `aks-up.sh`)
- `scripts/` — `start-minikube.sh`, `aks-up.sh` / `aks-down.sh`, `install.sh`,
  `verify.sh`, `port-forward.sh`, `resume.sh` (re-establish port-forwards
  after laptop sleep), `reset-demo.sh` (soft reset: wipe `workload` Jobs/pods
  + `helm upgrade --force-conflicts` to redeploy and reset the Kyverno policy,
  leaving core PKI up), `uninstall.sh`, `cleanup.sh` (forceful
  non-interactive reset), and the sourced helper
  `_cluster-detect.sh` (exports `CLUSTER_KIND`, `REGISTRY`, `CLUSTER_REGISTRY`,
  `ACR_LOGIN_SERVER`, `AKS_OIDC_ISSUER_URL`)
- `infra/aks/` — Terraform stack (local state); inlines the AVM `ptn-aks-dev` pattern
  to work around its hardcoded `Standard_DS2_v2` and `basic` load-balancer SKU
- `demos/demo[1-6]-*/run.sh` — idempotent demo scripts that auto-detect the cluster
- `.presentation/facts.yaml` — structured facts published for slide decks; consumed by
  `jamesbannan/presentations` (deck `zero-friction-devsecops`). Guarded by
  `scripts/check-presentation.sh` in CI — see `.presentation/README.md`
- `docs/architecture.md`, `docs/troubleshooting.md` — operator-facing docs
- `INSTRUCTIONS.md` — original build specification (retained as a design record)

## Common Commands

```bash
# Local
bash scripts/start-minikube.sh && bash scripts/install.sh && bash scripts/verify.sh

# AKS
az login && bash scripts/aks-up.sh && bash scripts/install.sh && bash scripts/verify.sh
bash scripts/aks-down.sh    # full teardown when finished (avoid idle cost)

# Demo image (required for demos 2, 3, 6; not for 1, 4, 5)
bash demos/demo-app/build-and-push.sh

# Demos (work on both targets)
bash demos/demo3-sigstore/run.sh

# Reset the demo without destroying AKS (much faster than aks-down + aks-up)
bash scripts/cleanup.sh
FORCE=true PURGE_CRDS=true bash scripts/cleanup.sh   # non-interactive, deep clean
```

## Conventions

- The talk's slides live in `jamesbannan/presentations`, not here. This repo publishes
  `.presentation/facts.yaml` and the deck reads it; when a demo's steps or the
  architecture change, update that file in the same commit and run
  `bash scripts/check-presentation.sh`.
- Cluster-aware behaviour lives in `scripts/_cluster-detect.sh`; scripts and demos
  should source it rather than re-implementing detection.
- Fulcio config goes through `scaffold.fulcio.config.contents` (a complete JSON blob
  with Pascal-case keys: `OIDCIssuers`, `IssuerURL`, `ClientID`, `Type`,
  `MetaIssuers`). The lowercase `oidcIssuers` path is silently ignored by the
  sub-chart.
- Fulcio configmap-only changes require `kubectl rollout restart deploy/fulcio-server -n fulcio-system`.
- Terraform is managed via `tfenv` (`tfenv use 1.15.3`); `terraform` resolves to a shim.
