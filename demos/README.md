# Demo Scripts

Six end-to-end demonstrations for the BSides Melbourne 2026 talk:
**"Zero-Friction DevSecOps: Automated Code Signing Done Right"**

## Prerequisites

All demos require the environment to be running:

```bash
bash scripts/start-minikube.sh   # Start the cluster
bash scripts/install.sh          # Deploy all components
bash scripts/verify.sh           # Confirm everything is healthy
bash demos/demo-app/build-and-push.sh  # Build and push the demo image
```

## Demo Overview

| # | Name | Script | Duration | What it shows |
|---|------|--------|----------|---------------|
| 1 | The Painful Baseline | `demo1-before/run.sh` | ~5 min | Manual GPG signing — the old way |
| 2 | Smallstep CA Signing | `demo2-smallstep/run.sh` | ~8 min | Short-lived certs, private PKI |
| 3 | Sigstore Keyless | `demo3-sigstore/run.sh` | ~8 min | No keys, OIDC identity, Rekor log |
| 4 | CI/CD Pipeline | `demo4-cicd/run.sh` | ~10 min | Automated build → sign → deploy |
| 5 | Policy Gate | `demo5-verification/run.sh` | ~8 min | Kyverno blocks unsigned images |
| 6 | Audit Trail | `demo6-audit/run.sh` | ~8 min | Attestations, CISO report |

**Total runtime:** ~47 minutes for all 6 demos in sequence.
**Recommended conference slot:** 45–60 minutes.

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

Override defaults with environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `REGISTRY` | `localhost:30500` | Registry endpoint |
| `IMAGE` | `localhost:30500/demo/app:latest` | Demo app image |
| `REKOR_URL` | `http://localhost:30300` | Rekor transparency log |
| `FULCIO_URL` | `http://localhost:30200` | Fulcio CA |
| `TUF_URL` | `http://localhost:30100` | TUF mirror |
| `STEP_CA_URL` | `https://localhost:39000` | Smallstep CA |

## Presenter Tips

- **Increase font size** before presenting — the audience needs to read the terminal
- **Use a dark terminal theme** — ANSI colours look best on dark backgrounds
- **Run `verify.sh` before the talk** — catch problems before you're on stage
- **Have the port-forwards running** — `bash scripts/port-forward.sh`
- **Keep each demo < 10 minutes** — audience attention peaks for shorter segments
- **For Demo 5**, the Kyverno enforcement takes 5–10 seconds to propagate after patching — build in a pause

## Troubleshooting

See `docs/troubleshooting.md` for common failure modes and fixes.

Quick checks:
```bash
bash scripts/verify.sh              # Full environment check
kubectl get pods -A                 # Check all pods are running
bash scripts/port-forward.sh        # Restart port-forwards if dropped
```
