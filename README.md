# DevSecOps Code Signing Demo

**Conference:** BSides Melbourne 2026
**Talk:** "Zero-Friction DevSecOps: Automated Code Signing Done Right"

A complete, self-contained demonstration environment that deploys a full code-signing stack
via a single `helm install`. Covers Smallstep CA signing, Sigstore keyless signing, Docker
Registry v2, and Kyverno policy enforcement — all running in a local Kubernetes cluster.

---

## Quickstart (~20 minutes)

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| minikube | 1.32+ | https://minikube.sigs.k8s.io/docs/start/ |
| Docker Desktop or Podman Desktop | — | https://www.docker.com/products/docker-desktop/ or https://podman-desktop.io/ |
| Helm | 3.14+ | https://helm.sh/docs/intro/install/ |
| kubectl | 1.29+ | https://kubernetes.io/docs/tasks/tools/ |
| cosign | 2.2.4+ | `brew install cosign` |
| step | 0.25+ | https://smallstep.com/docs/step-cli/installation/ |
| python3 | 3.8+ | Usually pre-installed on macOS/Linux |
| GnuPG | 2.x | `brew install gnupg` (required for Demo 1 only) |

> **Note:** On macOS with Docker Desktop, the Docker daemon runs inside a VM and cannot
> reach `localhost` port-forwards on the host. Registry push tests in `verify.sh` will
> report a warning in this configuration. In-cluster workloads are unaffected.

### Step 1 — Start the cluster

```bash
bash scripts/start-minikube.sh
```

This starts minikube with the Podman driver, containerd runtime, and the OIDC issuer
configuration required for Fulcio keyless signing. Takes ~2 minutes.

### Step 2 — Install the demo environment

```bash
bash scripts/install.sh
```

This runs `helm dependency update`, installs the umbrella chart, waits for core
infrastructure Deployments and StatefulSets to become ready, launches port-forwards,
and initialises the cosign TUF root. Takes ~10–15 minutes for all pods to become ready
(Trillian MySQL is the slowest component on Apple Silicon).

> The install uses a manual readiness check loop rather than `helm --wait` because
> demo workload Jobs are expected to remain incomplete until the demo image is built
> via `build-and-push.sh`.

### Step 3 — Verify everything is healthy

```bash
bash scripts/verify.sh
```

Runs 18 checks covering infrastructure health, Sigstore components, step-ca PKI,
registry connectivity, Kyverno policy, and end-to-end signing round-trips.
All should show `[PASS]` or `[WARN]`. Any `[FAIL]` — check `docs/troubleshooting.md`.

Checks 15, 16, and 18 will show `[WARN]` until you run `build-and-push.sh` and the
signing jobs complete.

### Step 4 — Build and push the demo app

```bash
bash demos/demo-app/build-and-push.sh
```

Builds the Go demo application and pushes it to the local registry at `localhost:30500`.

### Step 5 — Run the demos

```bash
bash demos/demo1-before/run.sh      # ~5 min — the painful baseline (GPG)
bash demos/demo2-smallstep/run.sh   # ~4 min — Smallstep CA signing (incl. 2-min cert expiry wait)
bash demos/demo3-sigstore/run.sh    # ~8 min — Sigstore keyless signing
bash demos/demo4-cicd/run.sh        # ~10 min — CI/CD pipeline simulation
bash demos/demo5-verification/run.sh # ~8 min — Kyverno policy enforcement
bash demos/demo6-audit/run.sh       # ~8 min — Attestations + CISO audit trail
```

See `demos/README.md` for presenter tips and environment variable overrides.

---

## Architecture

```
  Host                      Kubernetes Cluster (minikube)
  ────                      ──────────────────────────────
  cosign ──── port-forward ─→ Rekor        (transparency log)
  step   ──── port-forward ─→ Fulcio       (CA for keyless)
  docker ──── port-forward ─→ Registry v2  (image store)
                             → TUF          (trust root mirror)
                             → step-ca      (private PKI)
                             → Kyverno      (policy enforcement)
                             → demo-app     (workload)
```

**Port-forward endpoints** (started automatically by `install.sh`):

| Service | Host URL | In-cluster DNS |
|---------|----------|----------------|
| Docker Registry | `localhost:30500` | `registry.registry.svc:5000` |
| Rekor | `http://localhost:30300` | `rekor-server.rekor-system.svc:80` |
| Fulcio | `http://localhost:30200` | `fulcio-server.fulcio-system.svc:80` |
| TUF mirror | `http://localhost:30100` | `tuf-server.tuf-system.svc:80` |
| step-ca | `https://localhost:39000` | `devsecops-demo-stepca.pki.svc:9000` |

Full ASCII diagram and component descriptions: [`docs/architecture.md`](docs/architecture.md)

Two signing paths:
- **Smallstep CA** — private PKI, 2-minute code signing certs, Rekor transparency log, no external dependencies
- **Sigstore keyless** — public transparency log, OIDC identity, no long-lived keys

---

## Demo Flow

### Demo 1 — GPG Baseline (`demo1-before/run.sh`)
Shows the traditional approach: generate a GPG key, manually sign an artifact, verify
the signature. Highlights the pain points — long-lived keys, manual key management,
no expiry, no audit trail.

### Demo 2 — Smallstep CA Signing (`demo2-smallstep/run.sh`)
Issues a **2-minute code signing certificate** from the private Smallstep CA, signs
the container image with cosign, waits for the cert to expire, then verifies the
signature **still passes** — because the Rekor transparency log recorded the exact
signing timestamp. Key concepts demonstrated:
- Code Signing EKU restricts certificate usage
- Short-lived certs limit blast radius vs long-lived GPG keys
- Transparency log provides non-repudiation and temporal proof

### Demo 3–6
Sigstore keyless signing, CI/CD simulation, Kyverno policy enforcement, and
attestation audit trails. See `demos/README.md` for details.

---

## Code Signing Configuration

The Smallstep CA is configured via a post-install Helm hook
(`chart/templates/pki/stepca-codesigning-config.yaml`) that patches the CA's
provisioner configuration to:

1. Add an **x509 template** with `codeSigning` extended key usage (required by cosign v3)
2. Set `minTLSCertDuration: 30s` to allow short-lived demo certificates
3. Set `defaultTLSCertDuration: 5m` for workload signing jobs

The in-cluster signing job (`signing-job-smallstep`) uses the **JWK provisioner**
(`workload-signer`) with a provisioner password stored as a Kubernetes Secret.
Signatures are uploaded to the local Rekor transparency log, enabling verification
even after the signing certificate has expired.

---

## Cleanup

```bash
bash scripts/uninstall.sh   # Helm uninstall + optional namespace/cluster deletion
```

---

## Cloud Deployment

Override files for cloud environments:

```bash
# Azure AKS
helm upgrade --install devsecops-demo chart/ \
  -f chart/values-aks.yaml \
  --set global.registry=myacr.azurecr.io \
  --wait --timeout 15m

# AWS EKS
helm upgrade --install devsecops-demo chart/ \
  -f chart/values-eks.yaml \
  --set global.registry=123456789.dkr.ecr.ap-southeast-2.amazonaws.com \
  --wait --timeout 15m

# GCP GKE
helm upgrade --install devsecops-demo chart/ \
  -f chart/values-gke.yaml \
  --set global.registry=australia-southeast1-docker.pkg.dev/myproject/demo \
  --wait --timeout 15m
```

See the cloud values files for prerequisites (OIDC issuer configuration, registry auth, storage class).

---

## Repository Structure

```
devsecops-demo/
├── chart/                    ← Umbrella Helm chart
│   ├── Chart.yaml            ← Dependencies: scaffold + kyverno + step-certificates
│   ├── values.yaml           ← Local/minikube defaults
│   ├── values-aks.yaml       ← Azure overrides
│   ├── values-eks.yaml       ← AWS overrides
│   ├── values-gke.yaml       ← GCP overrides
│   └── templates/
│       ├── namespaces.yaml
│       ├── pki/              ← CA root propagation, TUF secret copy, code signing config
│       ├── registry/         ← Docker Registry v2
│       ├── workload/         ← Signing jobs + verification + demo app
│       └── policy/           ← Kyverno ClusterPolicies
├── scripts/
│   ├── start-minikube.sh
│   ├── install.sh
│   ├── port-forward.sh
│   ├── verify.sh
│   └── uninstall.sh
├── demos/
│   ├── demo-app/             ← Go HTTP server + Dockerfile
│   ├── demo1-before/         ← Manual GPG signing
│   ├── demo2-smallstep/      ← Smallstep CA path
│   ├── demo3-sigstore/       ← Sigstore keyless path
│   ├── demo4-cicd/           ← CI/CD simulation
│   ├── demo5-verification/   ← Policy enforcement
│   └── demo6-audit/          ← Attestations + audit trail
└── docs/
    ├── architecture.md
    └── troubleshooting.md
```

---

## Verification Checklist

The `scripts/verify.sh` script checks all of the following:

1. All namespaces exist and are Active
2. All Deployments have readyReplicas >= 1
3. step-ca /health returns ok
4. step-ca provisioner list includes workload-signer
5. Registry /v2/ returns {}
6. Registry push/pull round-trip
7. Rekor /api/v1/log returns valid treeSize
8. Rekor public key endpoint returns PEM
9. Fulcio /healthz returns ok
10. Fulcio root cert returns valid PEM
11. TUF root.json is available
12. cosign TUF root is initialised
13. OIDC issuer is https://kubernetes.default.svc
14. Kyverno running + ClusterPolicy exists
15. Smallstep signing round-trip
16. Sigstore keyless signing round-trip
17. Policy gate test
18. Attestation round-trip

---

## Known Issues

| Issue | Impact | Workaround |
|-------|--------|------------|
| **Docker Desktop VM networking** (macOS) | `docker push localhost:30500` fails because the daemon runs inside a HyperKit/QEMU VM that cannot reach host port-forwards | Use `crane` (runs on host) or push from inside the cluster. In-cluster workloads are unaffected. |
| **Trillian MySQL slow start** (Apple Silicon) | MySQL may take 2–3 minutes to pass readiness probes on ARM64 | `install.sh` allows up to 10 minutes. Probe timeouts are tuned in `values.yaml`. |
| **Workload Job warnings** | Checks 15/16/18 in `verify.sh` warn until the demo image exists | Run `demos/demo-app/build-and-push.sh` first, then re-run `verify.sh`. |

---

## License

MIT — see [LICENSE](LICENSE)
