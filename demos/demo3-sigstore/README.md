# Demo 3 — Sigstore Keyless Signing

## Prerequisites

- Stack deployed: `bash scripts/install.sh` (minikube or AKS) completed.
- Port-forwards running (automatic via `install.sh`) or ACR reachable on AKS.
- **Required:** the demo image must already exist in the registry. Run:
  ```bash
  bash demos/demo-app/build-and-push.sh
  ```
  This demo signs `${REGISTRY}/demo/app:latest`; if the image isn't there,
  `cosign sign` will fail.

## What this demo shows

The "modern Sigstore" path: **no long-lived keys at all**. A 10-minute
Kubernetes ServiceAccount JWT is used as the OIDC identity; Fulcio issues a
short-lived certificate bound to that identity; `cosign` signs the image with
an ephemeral key (discarded after use); Rekor logs the event; the signature
+ certificate are stored in the registry as OCI artefacts. Verification
re-checks the chain against the trusted root and asserts the identity claims.

Run it with:

```bash
bash demos/demo3-sigstore/run.sh
```

## What changes when the script runs

| Scope | Effect | Persists? |
|-------|--------|-----------|
| Kubernetes | Creates a fresh `signing-sa` SA token (audience=`sigstore`, 10-min TTL) — issued via `kubectl create token` | **No** (expires in 10 min; never written anywhere) |
| Fulcio | Issues one X.509 cert with SAN URI = `https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa`, expiry +10 min, signed by the in-cluster Fulcio root | Cert lives in the registry, not in Fulcio |
| Rekor | Appends one entry (kind: `hashedrekord` / `intoto`); `treeSize` increments by 1 | **Yes** (append-only) |
| Container registry | Adds an OCI 1.1 signature referrer (a separate manifest with `subject:` pointing at the image digest, containing the Fulcio cert + signature). Discover via `cosign tree`, the `/referrers` API, or the ACR Portal **Referrers** tab. | **Yes** |
| Filesystem | `/tmp/demo3-sigstore-XXXXXX/` — empty most of the time; only used as a temp space | **No** (`trap cleanup`) |

> The **ephemeral key never touches disk**. It exists only in `cosign`'s
> memory between the Fulcio response and the registry push.

## How to verify (CLI)

### 1. Look at the OIDC token the script feeds Fulcio

```bash
TOKEN=$(kubectl create token signing-sa -n workload --audience=sigstore --duration=10m)
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
# Key fields:
#   iss:  minikube → https://kubernetes.default.svc
#         AKS     → https://<region>.oic.prod-aks.azure.com/<tenant>/<cluster>/
#   sub:  system:serviceaccount:workload:signing-sa
#   aud:  ["sigstore"]
```

### 2. Confirm the new tlog entry

```bash
BEFORE=$(curl -s "${REKOR_URL:-http://localhost:30300}/api/v1/log" | jq -r .treeSize)
bash demos/demo3-sigstore/run.sh
AFTER=$(curl -s "${REKOR_URL:-http://localhost:30300}/api/v1/log" | jq -r .treeSize)
echo "Rekor grew by $((AFTER - BEFORE)) entries"   # expect: 1
```

Then fetch the latest entry directly (the script prints the `logIndex` it just
created — use that):

```bash
curl -s "${REKOR_URL:-http://localhost:30300}/api/v1/log/entries?logIndex=<N>" | \
  jq -r 'to_entries[0].value.body' | base64 -d | jq .
```

You should see `"kind": "hashedrekord"` and a base64-encoded public key /
certificate block.

### 3. Extract and inspect the Fulcio-issued cert

```bash
cosign download signature --allow-insecure-registry \
  "${REGISTRY:-localhost:30500}/demo/app:latest" | \
  jq -r '.[0].verificationMaterial.certificate.rawBytes // empty | select(length>0)' | \
  base64 -d | openssl x509 -inform DER -noout -text | head -40
# Look for:
#   Issuer:  O = Linux Foundation, ...   (the local Fulcio root)
#   Subject Alternative Name: URI:https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa
#   X509v3 1.3.6.1.4.1.57264.1.8  (OIDC Issuer extension)
#   Not After: only ~10 minutes after Not Before
```

### 4. Run the same verify the script runs

```bash
ISSUER=${AKS_OIDC_ISSUER_URL:-https://kubernetes.default.svc}
cosign verify \
  --rekor-url "${REKOR_URL:-http://localhost:30300}" \
  --certificate-identity "https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa" \
  --certificate-oidc-issuer "$ISSUER" \
  --allow-insecure-registry \
  --insecure-ignore-sct=true \
  "${REGISTRY:-localhost:30500}/demo/app:latest"
```

Try changing `--certificate-identity` to a bogus value — you should see
`no matching signatures` and the verification fails. That demonstrates that
signature substitution is detectable.

## How to verify (visual UIs)

| UI | minikube | AKS |
|----|----------|-----|
| Fulcio health | <http://localhost:30200/healthz> in your browser — expect `ok` | Same via port-forward |
| Rekor tree | <http://localhost:30300/api/v1/log> — refresh, watch `treeSize` and `rootHash` change | Same |
| Single Rekor entry | <http://localhost:30300/api/v1/log/entries?logIndex=N> | Same |
| Registry signature artefact | `cosign tree http://localhost:30500/demo/app:latest` shows a `via OCI referrer` line under the image digest | Azure Portal → **Container registries → `<acr-name>` → Repositories → `demo/app`** → click the image **digest** (not the `latest` tag) → **Referrers** tab. Or CLI: `az acr manifest list-referrers -r $ACR_NAME -n demo/app@<digest> -o table` |
| Registry referrers (signature manifest) | `cosign tree` resolves to the signature manifest digest | ACR Portal → **Referrers** tab on the image digest shows artifactType `application/vnd.dev.cosign.artifact.sig.v1+json` with the Fulcio cert + Rekor bundle in its annotations |
| Fulcio pod logs | `minikube dashboard` → namespace `fulcio-system` → `fulcio-server-*` → **Logs** — search for "issuing certificate" | Azure Portal → AKS → **Workloads** → namespace `fulcio-system` → `fulcio-server` → **Logs** |
| Rekor pod logs | `minikube dashboard` → `rekor-system/rekor-server-*` → **Logs** — see the new entry being appended | Azure Portal → AKS → Workloads → `rekor-system/rekor-server` → **Logs** |
| Local Sigstore UI (optional) | `docker run -p 3000:3000 sigstore/rekor-search-ui` then point it at `http://host.docker.internal:30300` | Same idea — point at the port-forwarded Rekor URL |

### Where is the signature in ACR? (Spoiler: there is no `.sig` tag)

cosign v3 stores signatures exclusively as **OCI 1.1 referrers** — a separate
manifest with a `subject:` field pointing at the image digest. There is **no
longer a `.sig` tag** in the registry; the legacy tag-based storage mode was
removed in cosign 3.0.

After signing, the demo3 script prints the OCI referrer digest. To inspect or
verify the signature:

```bash
# 1. Canonical view of everything attached to the image:
cosign tree "$ACR_LOGIN_SERVER/demo/app:latest"
# Look for: 🔗 https://sigstore.dev/cosign/sign/v1 artifacts via OCI referrer

# 2. List referrers directly via ACR's manifest API:
DIGEST=$(cosign triangulate --type=digest "$ACR_LOGIN_SERVER/demo/app:latest" | awk -F'@' '{print $2}')
az acr manifest list-referrers -r "$ACR_NAME" -n "demo/app@$DIGEST" -o table

# 3. Verify the signature — works identically regardless of storage mode:
cosign verify "$ACR_LOGIN_SERVER/demo/app:latest" \
  --certificate-identity-regexp '.*signing-sa.*' \
  --certificate-oidc-issuer "$AKS_OIDC_ISSUER_URL"
```

**In the ACR Portal:** Repositories → `demo/app` → click the image digest
(not the `latest` tag) → **Referrers** tab. You'll see one entry per signature
with artifactType `application/vnd.dev.cosign.artifact.sig.v1+json`.

Common surprises:
- `cosign tree` shows nothing → re-ran `build-and-push.sh` after signing? The
  `:latest` tag now points to a new digest. Signatures are bound to the **old**
  digest; re-run Demo 3 to sign the new one.
- Push failed silently → expired ACR token. `az acr login -n "$ACR_NAME"` and
  re-run demo 3.
- Cosign 2.x output → `cosign tree` shows `via tag:` lines instead of
  `via OCI referrer`. Demos target cosign v3+.

### Why no `.sig` tag any more?

Earlier cosign versions (≤ 2.x) defaulted to writing a `sha256-<digest>.sig`
tag on the same repository so the signature was "visible" in legacy registry
UIs. OCI 1.1 standardised a proper referrers API for this purpose, and cosign
3.0 removed the tag-based fallback entirely. The OCI referrer is the only
storage mode in modern cosign:

| Storage | What it looks like | Discovery |
|---------|--------------------|-----------|
| **OCI 1.1 referrer** (cosign v3) | Untagged signature manifest with `subject:` pointing at the image digest. | `cosign tree`, `/v2/<repo>/referrers/<digest>` API, `az acr manifest list-referrers`, ACR Portal **Referrers** tab. |
| ~~Legacy tag~~ (cosign ≤ 2.x) | ~~`sha256-<digest>.sig` tag on the same repository.~~ | ~~Visible in any registry tag list.~~ Removed in cosign 3.0. |

`cosign verify` is mode-agnostic — it understands both layouts and Just Works.

## Talking points to verify visually

- Compare the registry referrers before and after: no referrers existed
  prior to Demo 2; Demo 3 attaches a new signature manifest as a referrer
  of the image digest (visible via `cosign tree` or ACR Portal's Referrers tab).
- The Fulcio cert's SAN URI is `https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa`
  on **both targets** — even though the OIDC issuer URL is wildly different.
  This is what allows the same Kyverno policy to verify signatures from both
  clusters.
- In the Rekor pod logs you'll see the SHA-256 of the appended entry — that
  same hash appears in the registry's signature blob as the
  `signedEntryTimestamp`.

## minikube vs AKS notes

The signing flow is identical, but the OIDC issuer differs:

| | minikube | AKS |
|---|----------|-----|
| `kubectl create token` issuer | `https://kubernetes.default.svc` | `https://<region>.oic.prod-aks.azure.com/<tenant>/<cluster>/` |
| Fulcio config | `scaffold.fulcio.config.contents.OIDCIssuers` includes both URLs (rendered into `chart/values-aks.local.yaml` by `aks-up.sh`) | Same |
| `--certificate-oidc-issuer` flag (`verify`) | `https://kubernetes.default.svc` | `$AKS_OIDC_ISSUER_URL` |

The script picks the right issuer automatically via `_cluster-detect.sh`.
If your `verify` fails with `oidc issuer doesn't match`, source the helper
manually and confirm:

```bash
source scripts/_cluster-detect.sh
echo "CLUSTER_KIND=$CLUSTER_KIND  ISSUER=$AKS_OIDC_ISSUER_URL"
```

## Troubleshooting

**"There was an error processing the identity token"** (server-side Fulcio log)
means Fulcio's `OIDCIssuers` doesn't list the issuer your token claims. See
`docs/troubleshooting.md` §1 — usually fixed by re-running `aks-up.sh` and
`kubectl rollout restart deploy/fulcio-server -n fulcio-system`.

**`Error: signing [<image>]`** with `unauthorized` means the registry push
of the signature referrer was rejected — on AKS, run `az acr login -n $ACR_NAME`
to refresh the token (expires after ~3 hours).

## Cleanup

Nothing to clean. The new signature referrer in the registry and the new Rekor
entry are intentional, permanent demo state used by Demo 4/5/6.
