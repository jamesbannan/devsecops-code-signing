# Demo Scripts

Six end-to-end demonstrations for the talk
**"Zero-Friction DevSecOps: Automated Code Signing Done Right"**

## Prerequisites

All demos require the environment to be running. Pick a target:

**Local minikube:**

```bash
bash scripts/start-minikube.sh         # Start the cluster
bash scripts/install.sh                # Deploy all components
bash scripts/verify.sh                 # Confirm everything is healthy
bash demos/demo-app/build-and-push.sh  # Build and push the demo image
                                       # (required for demos 2, 3, 6; see matrix below)
```

**Azure AKS:**

```bash
az login && az account set --subscription <name|id>
bash scripts/aks-up.sh                 # terraform apply + render values-aks.local.yaml
bash scripts/install.sh                # auto-picks chart/values-aks.local.yaml
bash scripts/verify.sh
bash demos/demo-app/build-and-push.sh  # builds + az acr login + docker push to ACR
                                       # (required for demos 2, 3, 6; see matrix below)
```

All demo scripts source `scripts/_cluster-detect.sh` and adapt automatically — no flags
to pass. They detect `CLUSTER_KIND` (`minikube` or `aks`), pick the right registry, and
use the correct OIDC issuer when verifying signatures.

### Per-demo image prerequisites

`demos/demo-app/build-and-push.sh` produces `${REGISTRY}/demo/app:latest`. Which demos
need it pre-built?

| Demo | Needs `demo/app:latest` already in registry? | Why |
|------|---------------------------------------------|-----|
| 1 — GPG baseline   | Optional (falls back to placeholder digest) | Pedagogical — demonstrates manual GPG flow |
| 2 — Smallstep      | **Yes** | `cosign sign` against an existing image |
| 3 — Sigstore       | **Yes** | `cosign sign --identity-token` against the image |
| 4 — CI/CD pipeline | No — **builds + pushes itself** | Full BUILD → PUSH → SIGN pipeline |
| 5 — Policy gate    | No — builds its own `busybox` unsigned image | Demonstrates Kyverno blocking unsigned workloads |
| 6 — Audit trail    | **Yes** (ideally already signed by Demo 2 or 3) | Attests + replays signature/Rekor chain |

## Demo Overview

| # | Name | Script | Per-demo README | Duration | What it shows |
|---|------|--------|-----------------|----------|---------------|
| 1 | The Painful Baseline | `demo1-before/run.sh` | [demo1-before/README.md](demo1-before/README.md) | ~5 min | Manual GPG signing — the old way |
| 2 | Smallstep CA Signing | `demo2-smallstep/run.sh` | [demo2-smallstep/README.md](demo2-smallstep/README.md) | ~8 min | Short-lived certs, private PKI |
| 3 | Sigstore Keyless | `demo3-sigstore/run.sh` | [demo3-sigstore/README.md](demo3-sigstore/README.md) | ~8 min | No keys, OIDC identity, Rekor log |
| 4 | CI/CD Pipeline | `demo4-cicd/run.sh` | [demo4-cicd/README.md](demo4-cicd/README.md) | ~10 min | Automated build → sign → deploy |
| 5 | Policy Gate | `demo5-verification/run.sh` | [demo5-verification/README.md](demo5-verification/README.md) | ~8 min | Kyverno blocks unsigned images |
| 6 | Audit Trail | `demo6-audit/run.sh` | [demo6-audit/README.md](demo6-audit/README.md) | ~8 min | Attestations, CISO report |

Each per-demo README covers **what changes** in the cluster/registry/Rekor,
plus **CLI and GUI verification steps for both minikube and AKS**.

**Total runtime:** ~47 minutes for all 6 demos in sequence.
**Recommended conference slot:** 45–60 minutes.

### Pacing the demos on stage

Every demo script pauses between steps and waits for **ENTER** before
continuing — so you can narrate each step, answer audience questions, or
switch back to slides without the script racing ahead.

```bash
bash demos/demo3-sigstore/run.sh           # interactive — pauses between steps
DEMO_AUTO=1 bash demos/demo3-sigstore/run.sh   # skip prompts (rehearsals, CI)
bash demos/demo3-sigstore/run.sh < /dev/null   # also non-interactive (no TTY)
```

Pauses are suppressed automatically when stdin isn't a terminal (pipes,
redirects, CI), so `scripts/verify.sh`-style automation keeps working.

## Running Order

The demos are designed to run in order, each building on the previous:

```
Demo 1 → "This is the problem"
Demo 2 → "Here's path A (private PKI)"
Demo 3 → "Here's path B (public transparency)"
Demo 4 → "Here's how it fits in CI/CD"
Demo 5 → "Here's how it enforces policy"
Demo 6 → "Here's what the CISO sees"
```

You can also run them independently — each script sets up what it needs.

## Running a Demo

```bash
# From the repository root
bash demos/demo1-before/run.sh
bash demos/demo2-smallstep/run.sh
bash demos/demo3-sigstore/run.sh
bash demos/demo4-cicd/run.sh
bash demos/demo5-verification/run.sh
bash demos/demo6-audit/run.sh
```

All scripts are **idempotent** — safe to run multiple times.
All scripts have an **EXIT trap** that cleans up created resources.

## Environment Variables

Most defaults are auto-detected by `scripts/_cluster-detect.sh` based on the current
`kubectl` context. Override only when you need to point at something different.

| Variable | minikube default | AKS default | Description |
|----------|------------------|-------------|-------------|
| `CLUSTER_KIND` | `minikube` | `aks` | Auto-detected from context + node providerID |
| `REGISTRY` | `localhost:30500` | `<acr>.azurecr.io` | Host-side push target |
| `CLUSTER_REGISTRY` | `registry.registry.svc.cluster.local:5000` | `<acr>.azurecr.io` | In-cluster pull target |
| `IMAGE` | `localhost:30500/demo/app:latest` | `<acr>.azurecr.io/demo/app:latest` | Demo app image |
| `REKOR_URL` | `http://localhost:30300` | (port-forwarded) | Rekor transparency log |
| `FULCIO_URL` | `http://localhost:30200` | (port-forwarded) | Fulcio CA |
| `TUF_URL` | `http://localhost:30100` | (port-forwarded) | TUF mirror |
| `STEP_CA_URL` | `https://localhost:39000` | (port-forwarded) | Smallstep CA |
| `AKS_OIDC_ISSUER_URL` | _(unset)_ | `https://<region>.oic.prod-aks.azure.com/<tenant>/<cluster>/` | Used by demos 3/4/5/6 for `--certificate-oidc-issuer` on AKS |

## Presentation web UIs

Two optional browser UIs are wired into the chart for live demos (toggle with
`registryUi.enabled` / `rekorUi.enabled`, both `true` by default). Reach them via
`scripts/port-forward.sh` (minikube) or `kubectl port-forward` (AKS):

| UI | URL (minikube) | What it shows |
|----|----------------|---------------|
| **Registry browser** ([joxit](https://github.com/Joxit/docker-registry-ui)) | <http://localhost:30800> | `demo/app` repositories, tags, digests, referrers |
| **Rekor Search UI** ([sigstore](https://github.com/sigstore/rekor-search-ui)) | <http://localhost:30900> | Search the private transparency log by hash / identity |

The Registry UI uses a public image (no build needed). The Rekor UI is a
self-contained custom image that `scripts/install.sh` builds and pushes for you;
re-run `bash demos/rekor-ui/build-and-push.sh` only to rebuild it (see
[`demos/rekor-ui/README.md`](rekor-ui/README.md)).
Both run same-origin proxies, so neither the registry nor Rekor needs CORS config.

## Presenter Tips

- **Increase font size** before presenting — the audience needs to read the terminal
- **Use a dark terminal theme** — ANSI colours look best on dark backgrounds
- **Run `verify.sh` before the talk** — catch problems before you're on stage
- **Have the port-forwards running** — `bash scripts/port-forward.sh`
- **Keep each demo < 10 minutes** — audience attention peaks for shorter segments
- **For Demo 5**, the Kyverno enforcement takes 5–10 seconds to propagate after patching — build in a pause
- **To re-run the demos from scratch** (e.g. between rehearsals), run `bash scripts/reset-demo.sh`. It wipes the `workload` Jobs/pods, redeploys them, and resets the Kyverno `require-image-signature` policy that Demo 5 patches (back to `Audit` / `mutateDigest: false`) — all without tearing down the core PKI, so it's far faster than a full reinstall. The redeploy restarts step-ca (via its config hook), so `reset-demo.sh` also re-establishes the local port-forwards automatically; if `localhost:39000` ever goes dark outside a reset, run `bash scripts/port-forward.sh` (or `resume.sh`).
- **On AKS**: ACR access tokens expire after ~3 hours. Re-run `az acr login -n <acr>` if `docker push` starts returning 401. Run `bash scripts/aks-down.sh` between sessions to avoid idle cluster cost.

## Troubleshooting

See `docs/troubleshooting.md` for common failure modes and fixes.

Quick checks:
```bash
bash scripts/verify.sh              # Full environment check
kubectl get pods -A                 # Check all pods are running
bash scripts/port-forward.sh        # Restart port-forwards if dropped
```
