# =============================================================================
# Dockerfile — Self-contained Rekor Search UI (multi-stage build)
# =============================================================================
# Upstream sigstore/rekor-search-ui ships NO container image — it is a Next.js
# static export deployed to GitHub Pages. We build that static export ourselves
# and serve it from nginx, which ALSO reverse-proxies the Rekor API so the
# browser only ever talks to a single origin (no CORS needed — Rekor server
# does not emit CORS headers).
#
# Same-origin trick:
#   The Rekor JS client issues requests as `${BASE}/api/v1/...`. We build with
#   NEXT_PUBLIC_REKOR_DEFAULT_DOMAIN=/rekor (a RELATIVE base), so the browser
#   calls `/rekor/api/v1/...` against the UI's own origin. nginx proxies
#   `location /rekor/` to the in-cluster rekor-server, stripping the prefix.
#   Because the base is relative, the same image works unchanged on minikube
#   (localhost:30900) and AKS (ingress host) — nothing is hardcoded to a host.
#
# Build args:
#   REKOR_UI_REF — pinned git ref of sigstore/rekor-search-ui (reproducible build)
# =============================================================================

# --- Stage 1: Build the Next.js static export ---
FROM node:18-alpine AS build

RUN apk add --no-cache git

# Pinned to a known-good commit on the default branch. Bump deliberately.
ARG REKOR_UI_REF=4814ed26cf8142173eebc58ed1602e669bf548a2

WORKDIR /src
RUN git clone https://github.com/sigstore/rekor-search-ui.git . \
    && git checkout "${REKOR_UI_REF}"

# Work around an upstream regression present at the pinned ref: commit 3e428071
# ("backdown x509 dep", PR #98) changed the Subject Alternative Name handler to
# call .toJSON(), which does NOT exist on SubjectAlternativeNameExtension in the
# locked @peculiar/x509@1.14.2 (that class exposes .toTextObject()). The bad call
# breaks both the `next build` typecheck and, at runtime, the cert SAN view —
# which is exactly what this demo shows (the Fulcio service-account identity).
# Revert that single line to the previous, working .toTextObject() form. The
# guard keeps the build green if a future ref bump fixes the regression upstream.
RUN if grep -q 'SubjectAlternativeNameExtension(rawExtension.rawData).toJSON()' src/modules/x509/extensions.ts; then \
        sed -i 's/SubjectAlternativeNameExtension(rawExtension.rawData)\.toJSON()/SubjectAlternativeNameExtension(rawExtension.rawData).toTextObject()/' src/modules/x509/extensions.ts && \
        echo "Patched SAN extension handler: .toJSON() -> .toTextObject()"; \
    else \
        echo "SAN patch target not found (upstream may have fixed it) — skipping"; \
    fi

# Relative base → same-origin requests proxied by nginx (see header).
ENV NEXT_PUBLIC_REKOR_DEFAULT_DOMAIN=/rekor

# Next.js 15 static export (`output: "export"`) refuses to run while the default
# image-optimization loader is active — it requires `images.unoptimized = true`.
# Upstream's next.config.js (at the pinned ref) does not set it, so we rewrite a
# deterministic config that preserves the upstream settings and adds the flag.
# Pinned ref ⇒ this overwrite is reproducible; re-verify if REKOR_UI_REF is bumped.
RUN printf '%s\n' \
    '/** @type {import("next").NextConfig} */' \
    'const nextConfig = {' \
    '  reactStrictMode: true,' \
    '  output: "export",' \
    '  images: { unoptimized: true },' \
    '};' \
    'module.exports = nextConfig;' \
    > next.config.js

RUN npm ci && npm run build
# `output: "export"` in next.config.js writes the static site to ./out

# --- Stage 2: Serve via nginx + same-origin Rekor proxy ---
FROM nginx:1.27-alpine

# Static UI assets
COPY --from=build /src/out /usr/share/nginx/html

# nginx config template — REKOR_UPSTREAM is substituted at container start by
# the stock nginx entrypoint (envsubst over /etc/nginx/templates/*.template).
COPY nginx.conf.template /etc/nginx/templates/default.conf.template

# Default upstream; override via the REKOR_UPSTREAM env var in the Deployment.
ENV REKOR_UPSTREAM=rekor-server.rekor-system.svc.cluster.local:80

EXPOSE 8080
