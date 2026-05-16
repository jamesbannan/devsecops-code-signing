# TODO: Zero-Friction DevSecOps Demo — Helm Repository

> **Note (post-build):** This file is the **original implementation specification** used
> to generate the repository. It is retained as a design record. For the current
> operational state of the project, use these instead:
>
> - **README.md** — quickstart for both minikube and Azure Kubernetes Service
> - **demos/README.md** — running the six demo scripts (cluster auto-detected)
> - **docs/architecture.md** — current architecture, cluster-topology differences
> - **docs/troubleshooting.md** — failure modes for minikube **and** AKS
> - **infra/aks/README.md** — Terraform stack for the dev/test AKS environment
>
> Since this spec was written, AKS support has graduated from "values override" to a
> first-class deployment target: the repo now ships a Terraform stack (`infra/aks/`),
> bootstrap scripts (`scripts/aks-up.sh` / `aks-down.sh`), and a cluster-detection
> helper (`scripts/_cluster-detect.sh`) that lets `install.sh` and every demo script
> work identically on either cluster. Fulcio's `OIDCIssuers` config now lists both
> `https://kubernetes.default.svc` and the AKS-managed issuer URL.

## Context

This repository supports the conference talk **"Zero-Friction DevSecOps: Automated
Code Signing Done Right"** presented at BSides Melbourne 2026.

The goal is a **single `helm install` command** that brings up a complete, self-contained
code-signing demonstration environment on a local Kubernetes cluster (minikube + Podman
Desktop), which is also deployable to AKS, EKS, or GKE without modification.

Claude Code should read this entire file before writing any code. All implementation
decisions are specified here. Do not deviate from them without a clear technical reason,
and document any deviations as inline comments in the generated files.

---

## Target environment

| Property | Value |
|----------|-------|
| Local runtime | Podman Desktop + minikube |
| minikube driver | `podman` |
| Container runtime | `containerd` |
| Kubernetes version | 1.29+ |
| Helm version | 3.14+ |
| Cloud targets | AKS, EKS, GKE (via values override files) |
| Namespace strategy | One namespace per component group (see below) |

### Required minikube start flags

The cluster must be started with these flags before `helm install`. Generate a
`scripts/start-minikube.sh` that encapsulates them:

```bash
minikube start \
  --driver=podman \
  --container-runtime=containerd \
  --cpus=4 \
  --memory=6144 \
  --kubernetes-version=v1.29.0 \
  --insecure-registry="localhost:30500" \
  --extra-config=apiserver.service-account-issuer=https://kubernetes.default.svc \
  --extra-config=apiserver.service-account-api-audiences=https://kubernetes.default.svc
```

The `service-account-issuer` flag is mandatory for Fulcio keyless signing. Without it,
Kubernetes ServiceAccount JWTs will carry an unpredictable issuer URL that Fulcio cannot
validate.

---

## Repository layout

Generate the following structure. Do not add files outside this structure without
documenting why.

```
devsecops-demo/
├── README.md
├── TODO.md                          ← this file
│
├── chart/                           ← umbrella Helm chart
│   ├── Chart.yaml
│   ├── values.yaml                  ← default values (local/minikube)
│   ├── values-aks.yaml              ← Azure overrides
│   ├── values-eks.yaml              ← AWS overrides
│   ├── values-gke.yaml              ← GCP overrides
│   │
│   ├── charts/                      ← vendored sub-charts (helm dependency update)
│   │
│   └── templates/
│       ├── _helpers.tpl
│       ├── namespaces.yaml
│       ├── pki/                     ← Smallstep CA templates
│       ├── registry/                ← Docker Registry v2 templates
│       ├── workload/                ← demo app + signing jobs templates
│       └── policy/                  ← Kyverno ClusterPolicy templates
│
├── scripts/
│   ├── start-minikube.sh            ← minikube cluster bootstrap
│   ├── aks-up.sh                    ← AKS bootstrap (terraform apply + kubeconfig)
│   ├── aks-down.sh                  ← AKS full teardown (helm uninstall + destroy)
│   ├── _cluster-detect.sh           ← exports CLUSTER_KIND / REGISTRY / etc.
│   ├── install.sh                   ← helm install wrapper with pre-flight checks
│   ├── uninstall.sh                 ← interactive teardown (prompts before deleting)
│   ├── cleanup.sh                   ← non-interactive forceful reset (cluster stays up)
│   ├── port-forward.sh              ← starts all host-side port-forwards
│   ├── resume.sh                    ← restore port-forwards after laptop sleep
│   └── verify.sh                    ← end-to-end verification (all demos)
│
├── demos/
│   ├── README.md                    ← how to run each demo
│   ├── demo1-before/                ← Demo 1: the painful baseline
│   ├── demo2-smallstep/             ← Demo 2: Smallstep signing path
│   ├── demo3-sigstore/              ← Demo 3: Sigstore keyless path
│   ├── demo4-cicd/                  ← Demo 4: full CI/CD simulation
│   ├── demo5-verification/          ← Demo 5: verification as policy gate
│   └── demo6-audit/                 ← Demo 6: attestation + audit trail (CISO view)
│
└── docs/
    ├── architecture.md
    └── troubleshooting.md
```

---

## Umbrella chart specification

### Chart.yaml

```yaml
apiVersion: v2
name: devsecops-demo
description: >
  Automated code signing demonstration environment for BSides Melbourne 2026.
  Deploys Smallstep CA, Sigstore (Fulcio + Rekor + ctlog + TUF), Docker Registry v2,
  demo workloads, and Kyverno policy enforcement in a single helm install.
version: 0.1.0
type: application
keywords:
  - devsecops
  - code-signing
  - sigstore
  - smallstep
  - cosign
  - supply-chain
```

### Dependencies (chart/Chart.yaml dependencies block)

Use upstream Helm charts for the heavy infrastructure. Pin versions explicitly.

| Dependency | Chart | Repo | Version | Condition |
|-----------|-------|------|---------|-----------|
| Sigstore scaffold | `scaffold` | `https://sigstore.github.io/helm-charts` | `0.6.103` | `sigstore.enabled` |
| Kyverno | `kyverno` | `https://kyverno.github.io/kyverno/` | `3.2.6` | `kyverno.enabled` |
| step-ca | `step-certificates` | `https://smallstep.github.io/helm-charts` | `2.1.6` | `stepca.enabled` |

All three are stable, production-grade charts. Use them as-is via `helm dependency update`.

---

## Namespace strategy

Declare all namespaces in `chart/templates/namespaces.yaml`. Use a Helm helper to
conditionally create them based on which components are enabled.

| Namespace | Purpose |
|-----------|---------|
| `pki` | Smallstep CA (step-ca) |
| `registry` | Docker Registry v2 |
| `sigstore` | Helm release namespace for scaffold chart |
| `ctlog-system` | ctlog (created by scaffold chart) |
| `fulcio-system` | Fulcio (created by scaffold chart) |
| `rekor-system` | Rekor (created by scaffold chart) |
| `tuf-system` | TUF (created by scaffold chart) |
| `workload` | Demo application + signing Jobs |
| `policy` | Kyverno + ClusterPolicy |

The scaffold chart creates its own sub-namespaces. Do not conflict with them.

---

## Component specifications

### 1. Smallstep CA (`chart/templates/pki/`)

Use the `smallstep/step-certificates` Helm chart as a dependency. Configure it via
`values.yaml` under the `stepca:` key.

Key configuration requirements:
- Deploy into the `pki` namespace
- Use an **ephemeral CA** for local demo (no persistent key storage needed)
- Configure a JWK provisioner named `workload-signer` with:
  - Default cert duration: `5m`
  - Max cert duration: `10m`
  - `disableRenewal: false`
- Expose as ClusterIP on port 9000
- Publish the root CA cert as a ConfigMap named `step-ca-root` in the `pki`,
  `workload`, and `sigstore` namespaces so signing jobs and cosign can trust it
- The step-ca bootstrap (CA init) must be handled by a Kubernetes Job or the
  chart's built-in init mechanism — do NOT require manual `step ca init` on the host

Generate `chart/templates/pki/root-ca-propagation.yaml`: a Job that runs after
step-ca is ready, reads the root cert from the step-ca Secret, and creates/updates
the `step-ca-root` ConfigMap in `workload` and `sigstore` namespaces. Use an
appropriate RBAC Role/RoleBinding scoped to what the Job needs.

### 2. Docker Registry v2 (`chart/templates/registry/`)

Write this as a native chart template (no upstream dependency needed — registry:2 is
simple enough).

Requirements:
- Deploy into the `registry` namespace
- Image: `registry:2.8.3`
- Storage: PersistentVolumeClaim, 5Gi, `ReadWriteOnce`
- Delete enabled: `true` (needed for demo cleanup between runs)
- Service:
  - Local: `NodePort` on `30500`
  - Cloud (AKS/EKS/GKE): `ClusterIP` (access via ingress or internal tooling)
- ConfigMap-mounted `config.yml`
- No authentication (local demo — intentional, document it)

### 3. Sigstore scaffold (`sigstore:` values block)

Pass through values to the `sigstore/scaffold` dependency chart. The scaffold chart
creates and manages its own namespaces (`ctlog-system`, `fulcio-system`,
`rekor-system`, `tuf-system`).

Key values to set in `values.yaml`:
- `scaffold.fulcio.server.args.certificateAuthority: ephemeralca`
- `scaffold.fulcio.server.args.oidcIssuers`: configure for `https://kubernetes.default.svc`
- All ingress disabled (local mode)
- Fulcio service: ClusterIP port 80 + gRPC port 5554
- Rekor service: ClusterIP port 3000
- TUF service: ClusterIP port 80
- Resource requests/limits: kept low for minikube (see values below)

Resource budget per component for minikube:

| Component | CPU request | CPU limit | Mem request | Mem limit |
|-----------|------------|-----------|-------------|-----------|
| Trillian log-server | 100m | 300m | 128Mi | 256Mi |
| Trillian log-signer | 100m | 300m | 128Mi | 256Mi |
| Trillian MySQL | 100m | 300m | 256Mi | 512Mi |
| ctlog | 100m | 200m | 128Mi | 256Mi |
| Fulcio | 100m | 300m | 128Mi | 256Mi |
| Rekor | 100m | 300m | 128Mi | 256Mi |
| Rekor Redis | 50m | 100m | 64Mi | 128Mi |
| Rekor MySQL | 100m | 300m | 256Mi | 512Mi |
| TUF | 50m | 100m | 64Mi | 128Mi |

### 4. Workload demos (`chart/templates/workload/`)

Generate the following Kubernetes resources in the `workload` namespace:

#### 4a. Demo application image

The demo app is a minimal Go HTTP server that returns its build metadata
(version, git SHA, build timestamp) as JSON. Generate:
- `demos/demo-app/main.go` — the server
- `demos/demo-app/Dockerfile` — multi-stage build (golang:1.22-alpine → alpine:3.19)
- `demos/demo-app/build-and-push.sh` — builds and pushes to `localhost:30500/demo/app:latest`

The app should expose:
- `GET /` → `{"version":"1.0.0","sha":"<GIT_SHA>","built":"<TIMESTAMP>","signed":false}`
- `GET /healthz` → `{"status":"ok"}`

The `signed` field should be set to `true` when an environment variable
`IMAGE_SIGNED=true` is present, so the demo can visually distinguish signed from
unsigned deployments.

#### 4b. Signing Job A — Smallstep path (`workload/signing-job-smallstep.yaml`)

A Kubernetes Job that:
1. Pulls a pre-built image from the local registry
2. Requests a short-lived signing cert from step-ca using its ServiceAccount JWT
3. Uses `cosign sign --key` with the ephemeral cert to sign the image
4. Pushes the signature to the registry
5. Logs the cert fingerprint, cert expiry time, and registry digest

Use `gcr.io/projectsigstore/cosign:v2.2.4` as the signing container.
The Job's ServiceAccount must have `get` on the `step-ca-root` ConfigMap in
the `pki` namespace (add appropriate RBAC).

#### 4c. Signing Job B — Sigstore keyless path (`workload/signing-job-sigstore.yaml`)

A Kubernetes Job that:
1. Mounts the `sigstore-env` ConfigMap as environment variables
2. Requests a projected ServiceAccount token with audience `sigstore`
3. Uses `cosign sign` in keyless mode:
   - `--fulcio-url` from env
   - `--rekor-url` from env
   - `--identity-token` from the projected token file
   - `--tuf-mirror` from env
4. Logs the Rekor log index and entry UUID on success

#### 4d. Verification Job (`workload/verification-job.yaml`)

A Kubernetes Job that runs `cosign verify` against both signing paths and:
- Succeeds (exit 0) if a valid signature is present from either path
- Fails (non-zero exit) with a clear error message if unsigned
- Outputs a JSON summary: `{"image":"...","signed":true/false,"method":"smallstep|sigstore|none","rekor_entry":"..."}`

This is what gets wired up as the policy gate in Demo 5.

#### 4e. Intentional failure Jobs (`workload/failure-jobs.yaml`)

Three Jobs that demonstrate failure scenarios for Demo 4 (the "break things" segment):
1. `tampered-image-job` — pushes a layer-modified image and attempts verify (should fail)
2. `unsigned-deploy-job` — attempts to deploy an unsigned image (blocked by Kyverno)
3. `expired-cert-job` — annotated with a comment explaining that cert expiry is demonstrated
   by the 10-minute TTL on Smallstep certs; this Job shows what happens when you try to
   re-use a captured cert after expiry

### 5. Policy (`chart/templates/policy/`)

Install Kyverno via the upstream `kyverno/kyverno` Helm dependency.

Generate `chart/templates/policy/cluster-image-policy.yaml`:

A Kyverno `ClusterPolicy` (not a Sigstore `ClusterImagePolicy` — we're using Kyverno's
native cosign integration) that:
- Applies to all Pods in the `workload` namespace
- Requires images from `registry.registry.svc:5000/demo/*` to have a valid cosign
  signature
- Validates against either the Smallstep CA trust root OR the local Rekor log
- Generates a Kyverno `PolicyReport` on each admission for the audit trail demo
- Has `validationFailureAction: Audit` by default (switch to `Enforce` for Demo 5)

Include a second policy `audit-policy.yaml` that generates events for every signed image
admission — this is what Demo 6 uses to show the CISO-friendly audit trail.

---

## `values.yaml` structure

The default `values.yaml` should cover the local/minikube case completely. Structure it
as follows (generate the full file, not just this outline):

```yaml
global:
  environment: local        # local | aks | eks | gke
  registry: localhost:30500 # image registry for demo app
  imagePullPolicy: IfNotPresent

stepca:
  enabled: true
  namespace: pki
  # ... step-certificates chart values

registry:
  enabled: true
  namespace: registry
  nodePort: 30500
  storage: 5Gi

sigstore:
  enabled: true
  # scaffold chart values passed through
  scaffold:
    fulcio: ...
    rekor: ...
    ctlog: ...
    tuf: ...
    trillian: ...

kyverno:
  enabled: true
  namespace: policy
  # kyverno chart values

workload:
  enabled: true
  namespace: workload
  demoApp:
    image: localhost:30500/demo/app
    tag: latest
  signing:
    smallstep:
      enabled: true
    sigstore:
      enabled: true
  policy:
    validationFailureAction: Audit  # change to Enforce for Demo 5

hostAccess:
  # NodePort / port-forward configuration for host-side cosign CLI access
  rekor:
    nodePort: 30300
  fulcio:
    nodePort: 30200
  tuf:
    nodePort: 30100
```

### Cloud override files

Generate `values-aks.yaml`, `values-eks.yaml`, `values-gke.yaml` that override:
- `global.environment`
- `global.registry` (e.g. ACR endpoint for AKS)
- `registry.service.type: ClusterIP` (no NodePort in cloud)
- `hostAccess` section disabled
- Appropriate storage class names per cloud
- Any cloud-specific ingress annotations (placeholder comments are fine)

---

## Scripts

### `scripts/install.sh`

A wrapper around `helm install` that:
1. Runs pre-flight checks:
   - `minikube status` confirms cluster is running
   - OIDC issuer is `https://kubernetes.default.svc` (fails fast with clear message if not)
   - `helm`, `cosign`, `step` binaries are present on `$PATH`
2. Runs `helm dependency update chart/`
3. Runs `helm upgrade --install devsecops-demo chart/ --create-namespace --wait --timeout 15m`
4. Runs `scripts/port-forward.sh` automatically after install
5. Initialises cosign against the local TUF mirror
6. Prints a summary table of all endpoints

### `scripts/port-forward.sh`

Starts background port-forwards for all host-accessible services. Writes PIDs to
`/tmp/devsecops-pf.pids` so `uninstall.sh` can kill them. Services:

| Service | Namespace | Local port | Remote port |
|---------|-----------|-----------|-------------|
| Registry | registry | 30500 | 5000 |
| Rekor | rekor-system | 30300 | 3000 |
| Fulcio | fulcio-system | 30200 | 80 |
| TUF | tuf-system | 30100 | 80 |
| step-ca | pki | 39000 | 9000 |

### `scripts/verify.sh`

A comprehensive verification script with clearly labelled sections matching the demo
structure. Each check should print `[PASS]`, `[FAIL]`, or `[WARN]` in colour. The
script must be runnable at any point after install to confirm health.

Checks to include:
1. All expected namespaces exist and are `Active`
2. All Deployments have `readyReplicas >= 1`
3. step-ca `/health` returns `{"status":"ok"}`
4. step-ca provisioner list includes `workload-signer`
5. Registry `/v2/` returns `{}`
6. Registry push/pull round-trip with a test image
7. Rekor `/api/v1/log` returns a valid treeSize
8. Rekor public key endpoint returns a PEM key
9. Fulcio `/healthz` returns ok
10. Fulcio root cert endpoint returns a valid PEM cert
11. TUF `root.json` is available
12. cosign TUF root is initialised locally
13. OIDC issuer matches `https://kubernetes.default.svc`
14. Kyverno is running and has processed its ClusterPolicy
15. **End-to-end Smallstep signing round-trip** (sign + verify using step-ca cert)
16. **End-to-end Sigstore keyless round-trip** (sign + verify using Fulcio + Rekor)
17. **Policy gate test**: unsigned image rejected (or audited) by Kyverno
18. **Attestation test**: `cosign attest` + `cosign verify-attestation` round-trip

### `scripts/uninstall.sh`

- Kills all port-forwards from `/tmp/devsecops-pf.pids`
- Runs `helm uninstall devsecops-demo`
- Optionally deletes all namespaces (prompt the user)
- Optionally runs `minikube delete` (prompt the user)

### `scripts/cleanup.sh`

Forceful, non-interactive reset of the demo (cluster stays up). Use this when a
`helm uninstall` got stuck (orphan Kyverno webhooks, terminating namespaces,
PVC finalizers blocking namespace termination) and you want to re-run
`install.sh` without paying the AKS cluster creation cost again.

Order of operations:
1. Stop port-forwards from `/tmp/devsecops-pf.pids`.
2. Delete orphan Kyverno `Validating`/`MutatingWebhookConfigurations` **first** —
   otherwise the `failurePolicy: Fail` webhooks block all cluster-wide deletes.
3. `helm uninstall --no-hooks` (skips post-delete hook calls into the now-missing webhook).
4. Force-delete `pods,jobs,deployments,replicasets,statefulsets,daemonsets,cronjobs`
   in each demo namespace (`--grace-period=0 --force`).
5. Patch out PVC finalizers.
6. Optionally purge demo CRDs (`PURGE_CRDS=true`).
7. Wait up to `NS_WAIT_SECONDS` (default 60) for namespaces to terminate;
   clear remaining finalizers via the `/finalize` subresource as a last resort.

Environment variables: `FORCE=true` (skip prompt), `PURGE_CRDS=true`,
`NS_WAIT_SECONDS`, `RELEASE_NAME`, `HELM_NAMESPACE`.

### `scripts/resume.sh`

Restore the demo environment after the laptop has woken from sleep — without
re-running `install.sh`. Run this between sessions when you notice that
`curl localhost:30300` (or any other forwarded port) hangs or returns
connection-refused even though the cluster itself is still healthy.

Order of operations:
1. Detect cluster (minikube or AKS) via `_cluster-detect.sh`.
2. Verify the Kubernetes API is reachable. If not:
   - AKS: re-run `az aks get-credentials` (reads `infra/aks` terraform outputs);
     optionally `az login` first if `FORCE_AKS_REAUTH=1`.
   - minikube: `minikube start` if the VM has stopped.
3. Kill all surviving `kubectl port-forward` processes — both the PIDs recorded
   in `/tmp/devsecops-pf.pids` and any orphans bound to our well-known ports
   (30100/30200/30300/30500/39000).
4. Re-run `scripts/port-forward.sh`.
5. Probe each endpoint (Registry, Rekor, Fulcio, TUF, step-ca) with curl,
   retrying for up to ~5 seconds each.
6. If anything still fails, restart port-forwards once more and re-probe the
   broken ones; exit non-zero if they remain unreachable.

Environment variables: `FORCE_AKS_REAUTH=1` (run `az login` before
get-credentials).

---

## Demo scripts

Generate a runnable script for each demo under `demos/demoN-name/run.sh`. Each script
should be self-contained, idempotent, and print a clear narrative of what it's showing.
The scripts are designed to be run live on stage — keep commands short, outputs clear.

### `demos/demo1-before/run.sh` — The painful baseline

Show what manual signing looks like without automation:
1. Generate a GPG key pair (in a temp dir, clearly labelled as the "bad old way")
2. Sign a container image digest manually with GPG
3. Show the resulting `.sig` file
4. Point out: no audit trail, no expiry, no pipeline integration, key lives forever

Narrative output should include comments like `# This is what we're replacing`

### `demos/demo2-smallstep/run.sh` — Smallstep signing path

1. Show the step-ca provisioner list (certificate authority is running)
2. Request a 5-minute signing cert using the workload ServiceAccount JWT
3. Inspect the cert: show issuer, subject, and the 5-minute expiry
4. Sign `localhost:30500/demo/app:latest` using the cert
5. Show the signature stored in the registry (`cosign triangulate`)
6. Wait 6 minutes, then show that the cert is expired (key is already dead)
7. Verify the image — should still pass (cert was valid at time of signing)

### `demos/demo3-sigstore/run.sh` — Sigstore keyless path

1. Show the OIDC token contents (decoded JWT — issuer, subject, audience)
2. Run `cosign sign` keyless, showing Fulcio issuing the cert in real time
3. Show the Rekor transparency log entry (log index, entry UUID, body)
4. Show the cert embedded in the signature (who signed, when, which workflow)
5. `cosign verify` with explicit identity assertions
6. Pull the Rekor entry directly via the API and show the raw JSON

### `demos/demo4-cicd/run.sh` — CI/CD pipeline simulation

Simulate a GitHub Actions run locally using a shell script that mirrors the workflow:
1. "Build" step: `podman build` the demo app
2. "Push" step: push to local registry
3. "Sign" step: run both signing paths (Smallstep + Sigstore) as if they were
   workflow steps, with `echo "::group::Signing"` style output for familiarity
4. "Verify" step: run the verification job
5. "Deploy" step: apply a Deployment manifest — show Kyverno admitting the signed image

### `demos/demo5-verification/run.sh` — Verification as a policy gate

1. Switch Kyverno policy to `Enforce` mode (patch the ClusterPolicy)
2. Attempt to deploy an **unsigned** image — show Kyverno blocking it with the
   admission webhook error message
3. Attempt to deploy a **tampered** image (modified digest) — show cosign verify failing
4. Deploy a **correctly signed** image — show it admitted
5. Switch policy back to `Audit` mode at the end (idempotent cleanup)

### `demos/demo6-audit/run.sh` — Attestation + audit trail

1. Run `cosign attest` to attach an in-toto provenance attestation to the demo image
2. Show the attestation stored in the registry alongside the signature
3. Run `cosign verify-attestation` to confirm the attestation is valid
4. Pull the Kyverno PolicyReport for the workload namespace and format it clearly
5. Show the full chain: `git commit SHA → build → image digest → signature → Rekor entry`
6. Print a summary formatted as a "CISO report": who signed, when, from what identity,
   verified by what log

---

## `docs/architecture.md`

Generate a Markdown document containing:
- A text-based ASCII architecture diagram of the full stack
- Component descriptions (one paragraph each)
- Data flow description for each signing path (Smallstep and Sigstore)
- Port reference table
- Explanation of why the two paths are complementary (private PKI vs public transparency)

## `docs/troubleshooting.md`

Generate a troubleshooting guide covering the most common failure modes:

1. `OIDC issuer mismatch` — Fulcio rejects token; fix: reconfigure minikube
2. `TUF root not initialised` — cosign can't verify; fix: re-run cosign initialize
3. `Registry push fails` — insecure registry not trusted; fix: check Podman config
4. `step-ca not ready` — signing job can't get cert; fix: check pod logs, secret
5. `Kyverno webhook timeout` — policy enforcement blocks everything; fix: check Kyverno pods
6. `Rekor tree not initialised` — Trillian init job failed; fix: check job logs
7. `cosign verify fails after policy switch` — cert identity mismatch; fix: check issuer/subject flags
8. Port-forward dropped — common on macOS after sleep; fix: re-run port-forward.sh

---

## Implementation notes for Claude Code

1. **Start with `chart/Chart.yaml` and `chart/values.yaml`** — everything else derives
   from the values structure. Get these right before writing templates.

2. **Run `helm dependency update chart/` early** — this downloads the upstream charts
   into `chart/charts/`. Check them in (or add to `.gitignore` with a note — your call,
   but document the decision).

3. **Use `helm template` to validate templates as you go** — don't wait until the end.
   Run `helm template devsecops-demo chart/ --debug 2>&1 | head -50` after each major
   template to catch YAML errors early.

4. **The scaffold chart creates its own namespaces** — do not try to pre-create
   `ctlog-system`, `fulcio-system`, `rekor-system`, `tuf-system` in `namespaces.yaml`.
   Only pre-create `pki`, `registry`, `workload`, and `policy`.

5. **Kyverno admission webhook timing** — Kyverno must be fully ready before the
   ClusterPolicy is applied, or the webhook will reject its own CRDs. Use a Helm
   `post-install` hook with `helm.sh/hook-weight: "5"` on the ClusterPolicy, so it
   applies after Kyverno's webhook is registered.

6. **step-ca chart version** — the `smallstep/step-certificates` chart at `2.1.6` uses
   a `stepIssuer` CRD. We do not need the cert-manager integration; configure it with
   `certmanagerEnabled: false` and use the chart's built-in standalone mode.

7. **cosign version** — use `gcr.io/projectsigstore/cosign:v2.2.4` in all Job specs.
   This version supports both the `--identity-token` flag (keyless) and cert-based
   signing with `--certificate` / `--certificate-chain`.

8. **Registry insecure flag** — all `cosign` commands targeting the local registry need
   `--allow-insecure-registry`. All `podman` commands need `--tls-verify=false`. Make
   these flags conditional on `global.environment == "local"` in templates where
   possible, defaulting to secure in cloud environments.

9. **Projected ServiceAccount tokens** — signing jobs that use Sigstore keyless need
   a projected token with audience `sigstore` and a short expiry (`expirationSeconds: 600`).
   Use `spec.volumes[].projected.sources[].serviceAccountToken` — do not use the default
   mounted token.

10. **Demo script idempotency** — every `demos/demoN/run.sh` must be safe to run
    multiple times. Use `--dry-run=client` where possible, and clean up created resources
    at the end of each script (or provide a `cleanup` function called on EXIT trap).

11. **Colour and formatting in scripts** — use ANSI colour codes for demo output.
    Headers in cyan, commands in yellow, success in green, failure in red. The audience
    is watching a projected screen — make it readable at distance.

12. **Do not use `latest` tags** for any infrastructure images. Pin every image to a
    specific digest or semver tag. The demo must be reproducible.

---

## Definition of done

The implementation is complete when:

- [ ] `bash scripts/start-minikube.sh` starts a correctly configured cluster
- [ ] `bash scripts/install.sh` completes without errors in under 15 minutes
- [ ] `bash scripts/verify.sh` passes all 18 checks
- [ ] `bash demos/demo1-before/run.sh` through `demos/demo6-audit/run.sh` each
      run without errors and produce clear, readable output
- [ ] `helm template devsecops-demo chart/` produces valid YAML with no errors
- [ ] `helm lint chart/` passes with no warnings
- [ ] The README contains a quickstart that a conference attendee could follow
      to reproduce the environment from scratch in under 20 minutes
- [ ] `values-aks.yaml`, `values-eks.yaml`, `values-gke.yaml` exist with
      appropriate cloud-specific overrides and placeholder comments for
      cloud-specific values (registry URL, storage class, etc.)