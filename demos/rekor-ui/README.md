# Rekor Search UI — `demo/rekor-ui`

A **self-contained** build of the [Sigstore Rekor Search UI](https://github.com/sigstore/rekor-search-ui)
for browsing this demo's **private** Rekor transparency log in a presentation.

```
demos/rekor-ui/
├── Dockerfile           ← multi-stage: Next.js static export + nginx proxy
├── nginx.conf.template  ← serves the UI and same-origin-proxies the Rekor API
├── build-and-push.sh    ← build + push to the demo registry
└── README.md            ← this file
```

## Why a custom image?

Upstream `sigstore/rekor-search-ui` ships **no container image** — it is a Next.js
static export hosted on GitHub Pages, hardcoded to the public `rekor.sigstore.dev`.
Two problems make it unusable as-is against a private Rekor:

1. **No image to deploy.** We build the static export ourselves.
2. **No CORS on Rekor.** `rekor-server` emits no `Access-Control-Allow-Origin`
   header, so a browser UI on a different origin/port is blocked.

### How this image solves both

The image bakes the UI with `NEXT_PUBLIC_REKOR_DEFAULT_DOMAIN=/rekor` — a
**relative** base. The Rekor JS client then issues requests as `/rekor/api/v1/...`
against the UI's **own origin**, and the bundled nginx reverse-proxies
`location /rekor/` to the in-cluster `rekor-server` (stripping the prefix). The
browser only ever talks to one origin, so **no CORS is needed**, and because the
base is relative the same image works unchanged on minikube (`localhost:30900`)
and AKS (ingress host) — nothing is pinned to a hostname.

```
browser ──/rekor/api/v1/log──▶ rekor-ui (nginx :8080) ──/api/v1/log──▶ rekor-server.rekor-system:80
         ◀── static UI assets ──
```

### Build-time source patches

The image pins a specific upstream commit (`REKOR_UI_REF`) and the `Dockerfile`
applies two small, self-documented fixes to make that commit build and run, because
upstream `main` does **not** cleanly produce a static export at the time of writing:

1. **SAN handler regression.** Upstream commit `3e428071` ("backdown x509 dep", PR
   #98) changed the Subject Alternative Name extension handler to call `.toJSON()`,
   which does not exist on `SubjectAlternativeNameExtension` in the locked
   `@peculiar/x509@1.14.2` (it exposes `.toTextObject()`). This breaks both the
   `next build` typecheck and the **runtime cert SAN view** — the exact thing this
   demo shows (the Fulcio service-account identity). The Dockerfile reverts that one
   line to `.toTextObject()` (the form used before the regression). The patch is
   guarded, so it silently no-ops if a future ref already fixes it.
2. **Static-export image flag.** Next.js 15 refuses `output: "export"` while the
   default image-optimization loader is active. The Dockerfile rewrites
   `next.config.js` to add `images.unoptimized = true` (preserving the upstream
   `output: "export"` / `reactStrictMode` settings).

The build stage uses `node:18-alpine` to match upstream's declared `engines.node:
18.x`. **If you bump `REKOR_UI_REF`, re-verify both patches still apply** (rebuild
and confirm the SAN extension renders) and adjust or drop them as upstream evolves.

## What it produces

| Item | Value |
|------|-------|
| Image name | `${REGISTRY}/demo/rekor-ui:latest` (override with `IMAGE_NAME` / `IMAGE_TAG`) |
| Registry (minikube) | `localhost:30500` (NodePort-mapped to the in-cluster registry) |
| Registry (AKS) | `<acr-login-server>` (from Terraform output) |
| Upstream ref | `sigstore/rekor-search-ui` pinned via `REKOR_UI_REF` build arg |

## Prerequisites

The cluster is up and one of `minikube` / `docker` / `podman` is on PATH. The
`minikube` path pushes to the registry via its ClusterIP (`ctr`) and needs **no**
port-forward — so `install.sh` can build this image before starting port-forwards.
The `docker` / `podman` fallback pushes to `localhost:30500` and therefore needs
the registry port-forward active; on AKS the image goes to ACR (`az` logged in).

## Usage

`scripts/install.sh` already builds and pushes this image (best-effort) so the
`rekor-ui` Deployment comes up Ready on a fresh install. Run the script below
manually only to **rebuild** — for example after bumping `REKOR_UI_REF`, or if the
in-install build failed (e.g. no build tool on PATH).

```bash
# Build + push (auto-detects the right registry from _cluster-detect.sh)
bash demos/rekor-ui/build-and-push.sh

# Pin a different upstream commit of rekor-search-ui
# (re-verify the Dockerfile's build-time patches still apply — see above)
REKOR_UI_REF=<git-sha> bash demos/rekor-ui/build-and-push.sh
```

The chart deploys this image as the `rekor-ui` Deployment in the `registry`
namespace (gated by `rekorUi.enabled`, default `true`). After the image is pushed
and port-forwards are running, open:

```
http://localhost:30900        # minikube
```

On AKS the Service is `ClusterIP`; reach it with:

```bash
kubectl port-forward svc/rekor-ui 30900:8080 -n registry
```

## Demo tips

- Run a signing demo first (e.g. `demos/demo3-sigstore/run.sh`) so there are
  entries in the log, then search the UI by the image **hash** (`sha256:…`) or by
  the signer **email/identity**.
- The Settings panel shows the configured Rekor server as `/rekor` — that is the
  same-origin proxy path, not a bug. Leave it as-is.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `rekor-ui` pod in `ImagePullBackOff`, registry `_catalog` empty | image never built/pushed (e.g. fresh install where the in-`install.sh` build was skipped or failed) | `bash demos/rekor-ui/build-and-push.sh` (it pushes the image and rolls the Deployment) |
| UI loads but searches spin / 502 | `rekor-server` not ready, or `REKOR_UPSTREAM` wrong | `kubectl get pods -n rekor-system`; check `rekorUi.rekorUpstream` in values |
| `http://localhost:30900` refused | port-forward not running | `bash scripts/port-forward.sh` |
| Searches hit the public `rekor.sigstore.dev` | image built without `NEXT_PUBLIC_REKOR_DEFAULT_DOMAIN=/rekor` | rebuild with this script (it sets it) |
| Pod CrashLoopBackOff on AKS, exec format error | arm64 image on amd64 nodes | rebuild — the script forces `linux/amd64` on AKS |
| Build fails: `toJSON does not exist` or `Image Optimization … not compatible with export` | a bumped `REKOR_UI_REF` no longer matches the Dockerfile's build-time patches | see [Build-time source patches](#build-time-source-patches) and re-apply/adjust |

## See also

- [`demos/demo-app/README.md`](../demo-app/README.md) — the image-build pattern this mirrors
- [`demos/demo6-audit/README.md`](../demo6-audit/README.md) — the audit demo that pairs with this UI
- [`docs/architecture.md`](../../docs/architecture.md) — where the UIs sit in the stack
