# Demo App — `demo/app`

A tiny Go HTTP server that serves as the **subject of every signing demo** in
this repository. Built by `build-and-push.sh` and pushed to the demo registry
(either the in-cluster Docker registry on minikube or your ACR on AKS).

```
demos/demo-app/
├── main.go            ← Go HTTP server: GET / → "Hello from demo-app"
├── go.mod
├── Dockerfile         ← multi-stage build, scratch-based, ~6 MB final image
├── build-and-push.sh  ← build, push, and print verification cheat-sheet
└── README.md          ← this file
```

## What it produces

| Item | Value |
|------|-------|
| Image name | `${REGISTRY}/demo/app:latest` (override with `IMAGE_NAME` and `IMAGE_TAG`) |
| Registry (minikube) | `localhost:30500` (NodePort-mapped to in-cluster Distribution v2) |
| Registry (AKS) | `<acr-login-server>` (from Terraform output) |
| Labels / build args | `GIT_SHA` and `BUILD_TIME` embedded so every push gets a unique digest |

The image is **unsigned** when `build-and-push.sh` finishes — that's the whole
point. The signing happens later, in demos 2, 3, 4, or 6.

## Prerequisites

| Target | What you need |
|--------|--------------|
| minikube | `bash scripts/start-minikube.sh && bash scripts/install.sh` already ran; port-forwards active (or run `bash scripts/port-forward.sh` again) |
| AKS | `bash scripts/aks-up.sh && bash scripts/install.sh` already ran; `az` logged in to the same subscription |
| Both | One of `minikube`, `docker`, or `podman` on PATH for the build step |

## Usage

```bash
# Defaults — picks the right registry from _cluster-detect.sh.
# On AKS, automatically builds for linux/amd64 (default node arch).
bash demos/demo-app/build-and-push.sh

# Custom tag
IMAGE_TAG=v1.2.3 bash demos/demo-app/build-and-push.sh

# Force a specific registry (e.g. push the minikube image to ACR)
REGISTRY=acrdsoacs5fut5.azurecr.io bash demos/demo-app/build-and-push.sh

# Override the target platform (arm64 AKS node pool, custom build matrix, etc.)
TARGET_PLATFORM=linux/arm64 bash demos/demo-app/build-and-push.sh
```

The script prefers tools in this order:

| Cluster | Preference | Why |
|---------|-----------|-----|
| AKS     | `docker` → `podman` | ACR push needs a real OCI client over HTTPS |
| minikube | `minikube image build` → `podman` → `docker` | Avoids macOS VM ↔ host networking headaches |

## Verifying the push

The script prints a **"How to verify"** cheat-sheet on every run, customised for
your cluster. The commands below are what it produces — keep this handy if you
re-run only parts of the demo and need to confirm the image is where you expect.

### 1. List tags / repositories

**minikube:**
```bash
curl -s http://localhost:30500/v2/_catalog | jq
curl -s http://localhost:30500/v2/demo/app/tags/list | jq
```

**AKS:**
```bash
az acr repository list      -n "$ACR_NAME" -o table
az acr repository show-tags -n "$ACR_NAME" --repository demo/app -o table
```

### 2. Inspect the manifest and digest

**minikube:**
```bash
curl -s \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  http://localhost:30500/v2/demo/app/manifests/latest | jq
```

**AKS:**
```bash
az acr manifest show       -r "$ACR_NAME" -n demo/app:latest
az acr repository show     -n "$ACR_NAME" --image demo/app:latest
```

You should see a `config.digest` of the form `sha256:…` — that's the **immutable
identity** of the image. Every signing demo signs this digest, not the `:latest`
tag.

### 3. Pull and run from any client

```bash
docker pull "${REGISTRY}/demo/app:latest"
crane manifest "${REGISTRY}/demo/app:latest"     # if you have crane installed
```

### 4. Confirm Kubernetes can pull and run it

```bash
kubectl run demo-pull-test --rm -it --restart=Never \
  --image="${REGISTRY}/demo/app:latest" -- /demo-app --version
```

(While the `require-image-signature` Kyverno policy is in **Audit** mode this
will admit; once flipped to **Enforce** in Demo 5, this same command must fail.)

### 5. Inspect with cosign

```bash
# minikube:
cosign tree --allow-insecure-registry "localhost:30500/demo/app:latest"
# AKS:
cosign tree "$ACR_LOGIN_SERVER/demo/app:latest"
```

Before any signing demo runs, `cosign tree` will show only the image manifest —
no signature or attestation referrers. After Demo 2 or 3, you'll see signature
referrers attached to the image digest (cosign v3 stores them as OCI 1.1
referrers, not as separate `.sig` tags).

### 6. Visual / UI checks

| Cluster | Where to look |
|---------|--------------|
| minikube | `http://localhost:30500/v2/_catalog` and `http://localhost:30500/v2/demo/app/tags/list` in a browser. minikube dashboard → Workloads → Pods → `registry` (logs show `PUT /v2/demo/app/manifests/latest`). |
| AKS | Azure Portal → **Container registries** → your ACR → **Repositories** → `demo/app` → tag `latest`. The pane shows digest, size, last-updated, OS/architecture. |

## What this image looks like

```dockerfile
# Dockerfile (multi-stage, scratch-based)
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY . .
ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.gitSHA=$GIT_SHA -X main.buildTime=$BUILD_TIME" \
    -o /demo-app .

FROM scratch
COPY --from=build /demo-app /demo-app
ENTRYPOINT ["/demo-app"]
```

The Go binary serves a one-line HTTP response with the embedded build metadata —
useful when you want to prove a Pod is running the freshly-signed image and not
a cached older version.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `No container build tool found` | Neither `minikube`, `docker`, nor `podman` on PATH | Install Docker Desktop, Podman, or start minikube |
| `Registry at localhost:30500 is not reachable` | port-forward died (common after macOS sleep) | `bash scripts/port-forward.sh` |
| `unauthorized: authentication required` (AKS) | `az` token expired or wrong subscription | `az login && az acr login -n "$ACR_NAME"` |
| `manifest unknown` from `curl` after a successful push | You ran `minikube ssh -- ctr push` but the in-cluster registry isn't running the requested service | `kubectl get svc -n registry registry` — confirm `ClusterIP` and check pod logs |
| Push succeeds but signature demos fail with `image not found` | `REGISTRY` env var mismatched between push and demo runs | Re-run with the same `REGISTRY` value, or unset it and let `_cluster-detect.sh` decide |
| Pod CrashLoopBackOff on AKS, exit code 255, no useful container logs | Image built for arm64 on Mac M-series; AKS nodes are amd64 → exec format error | Re-run `build-and-push.sh` — it now forces `linux/amd64` on AKS automatically. For arm64 node pools set `TARGET_PLATFORM=linux/arm64`. |

## See also

- [`demos/README.md`](../README.md) — overview of all six demos and which need `build-and-push.sh` first
- [`docs/troubleshooting.md`](../../docs/troubleshooting.md) — common failures across the stack
- [`scripts/_cluster-detect.sh`](../../scripts/_cluster-detect.sh) — the helper that selects the right registry on each cluster
