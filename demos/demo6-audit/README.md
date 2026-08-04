# Demo 6 — Attestation + Audit Trail (CISO view)

## Prerequisites

- Stack deployed: `bash scripts/install.sh` (minikube or AKS) completed.
- Port-forwards running (automatic via `install.sh`) or ACR reachable on AKS.
- **Required:** the demo image must already exist in the registry, and ideally
  has been signed (Demo 2 or Demo 3 leaves a Sigstore signature attached). Run:
  ```bash
  bash demos/demo-app/build-and-push.sh
  bash demos/demo3-sigstore/run.sh    # or demo2-smallstep
  ```
  Demo 6 attaches an attestation to `${REGISTRY}/demo/app:latest` and replays
  the full signature → Rekor → audit chain.

## What this demo shows

The "compliance close-out" demo. An **in-toto SLSA-provenance attestation**
is generated, attached to `demo/app:latest` via `cosign attest` (keyless),
recorded in Rekor, and then verified with `cosign verify-attestation` (which
requires the same `--certificate-identity` / `--certificate-oidc-issuer`
flags as a normal signature verify). The script then aggregates everything
the cluster knows about the image and prints a CISO-style audit report
covering source code SHA, build time, image digest, signatures, attestations,
the Rekor tree size, the Kyverno ClusterPolicy in force, and a count of
PolicyReports.

Run it with:

```bash
bash demos/demo6-audit/run.sh
```

## What changes when the script runs

| Scope | Effect | Persists? |
|-------|--------|-----------|
| Container registry | Adds an **attestation** OCI artefact as an OCI 1.1 referrer (a separate manifest with `subject:` pointing at the image digest) alongside the image's existing signature referrer | **Yes** |
| Fulcio | Issues a fresh 10-minute cert (for the attest step) | Embedded in attestation; cert itself ephemeral |
| Rekor | Appends one entry (kind: `intoto`, predicateType: `slsaprovenance`); `treeSize` +1 | **Yes** |
| Kubernetes | None directly — only **reads** PolicyReports, secrets, and image manifests | n/a |
| Filesystem | `/tmp/demo6-audit-XXXXXX/provenance.json` (the SLSA predicate the script generated) | **No** |

The attestation predicate baked into the registry includes:

- `builder.id` = `https://github.com/actions/runner` (fictional, for the demo)
- `invocation.configSource.uri` = `git+https://github.com/jamesbannan/devsecops-code-signing`
- `invocation.configSource.digest.sha1` = **the real git SHA** of your checkout
- `metadata.buildStartedOn` / `buildFinishedOn` = run timestamp
- `materials[]` referencing the same git SHA

## How to verify (CLI)

### 1. Confirm the new attestation referrer exists

```bash
cosign tree --allow-insecure-registry "${REGISTRY:-localhost:30500}/demo/app:latest"
# Expect (cosign v3 uses OCI 1.1 referrers — there are no .sig/.att tags):
#   └── 🔗 ... artifacts via OCI referrer: .../demo/app@sha256:<digest>
#       ├── 🍒 sha256:<sig-manifest>      (signature)
#       └── 🍒 sha256:<att-manifest>      (attestation)
```

### 2. Pull and decode the attestation payload

```bash
cosign download attestation --allow-insecure-registry \
  "${REGISTRY:-localhost:30500}/demo/app:latest" | \
  jq -r .payload | base64 -d | jq .
# Expect a full in-toto Statement with:
#   predicateType: https://slsa.dev/provenance/v0.2
#   subject[]: { name: ..., digest: { sha256: ... } }
#   predicate: { builder, invocation, metadata, materials }
```

### 3. Reproduce the verify

```bash
ISSUER=${AKS_OIDC_ISSUER_URL:-https://kubernetes.default.svc}
cosign verify-attestation \
  --type slsaprovenance \
  --certificate-identity "https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa" \
  --certificate-oidc-issuer "$ISSUER" \
  --allow-insecure-registry --insecure-ignore-sct=true \
  "${REGISTRY:-localhost:30500}/demo/app:latest" | \
  jq -r .payload | base64 -d | jq -r .predicate.invocation.configSource.digest.sha1
# Expect: the same git SHA that the script printed in the CISO report.
```

### 4. Cross-reference with the Rekor entry

```bash
# The verify output contains the tlog entry's logIndex — fetch the raw entry:
INDEX=...   # from verify-attestation output, the "logIndex" field
curl -s "${REKOR_URL:-http://localhost:30300}/api/v1/log/entries?logIndex=$INDEX" | \
  jq -r 'to_entries[0].value.body' | base64 -d | jq '{kind, apiVersion, spec: { content: .spec.content[:80] }}'
# Expect kind: "intoto", apiVersion: "0.0.2"
```

### 5. PolicyReport snapshot (for the CISO report)

```bash
kubectl get policyreport -n workload --no-headers | wc -l           # count printed by script
kubectl get policyreport -n workload -o json | \
  jq '[.items[].results[] | select(.policy=="require-image-signature")] | group_by(.result) | map({result: .[0].result, count: length})'
# Expect: a list like [{"result":"pass","count":N},{"result":"fail","count":M}]
```

### 6. End-to-end provenance chain — one-liner

```bash
IMAGE="${REGISTRY:-localhost:30500}/demo/app:latest"
echo "Image:    $IMAGE"
echo "Digest:   $(docker manifest inspect $IMAGE 2>/dev/null | jq -r .config.digest)"
echo "Signed:   $(cosign tree --allow-insecure-registry $IMAGE 2>&1 | grep -c sha256-)"
echo "Attested: $(cosign download attestation --allow-insecure-registry $IMAGE 2>&1 | jq -r .payload | base64 -d | jq -r .predicate.invocation.configSource.digest.sha1)"
echo "RekorN:   $(curl -s ${REKOR_URL:-http://localhost:30300}/api/v1/log | jq -r .treeSize)"
```

## How to verify (visual UIs)

| UI | minikube | AKS |
|----|----------|-----|
| Attestation referrer in registry | `cosign tree http://localhost:30500/demo/app:latest` — a **new** `via OCI referrer` line appears under the image digest after this demo | Azure Portal → ACR → **Repositories → demo/app** → click the image **digest** → **Referrers** tab — a new row appears with artifactType `application/vnd.dev.cosign.artifact.sbom.v1+json` (DSSE-wrapped SLSA predicate) |
| Attestation manifest contents | `cosign download attestation http://localhost:30500/demo/app:latest \| jq -r .payload \| base64 -d \| jq` — DSSE envelope wrapping the in-toto predicate | ACR Portal → click the new referrer row → **Manifest** tab |
| Rekor entry detail | <http://localhost:30300/api/v1/log/entries?logIndex=N> in a browser — look for `"kind": "intoto"` | Same via port-forward |
| **Rekor Search UI** | Open <http://localhost:30900> (built-in, wired into the chart) — search by image **hash** (`sha256:…`) or signer **email/identity**. Needs `bash demos/rekor-ui/build-and-push.sh` once + port-forwards. | `kubectl port-forward svc/rekor-ui 30900:8080 -n registry`, then <http://localhost:30900> |
| **Registry browser UI** | Open <http://localhost:30800> (built-in [joxit](https://github.com/Joxit/docker-registry-ui), wired into the chart) — browse `demo/app`, its tags, digests, and signature/attestation referrers | Azure Portal → ACR → **Repositories**, or `kubectl port-forward svc/registry-ui 30800:80 -n registry` |
| Kyverno PolicyReports | Dashboard → ns `workload` → **Custom Resources → policyreports.wgpolicyk8s.io** (depends on dashboard CRD support) | Azure Portal does not surface CRDs in the GUI; use `kubectl` |
| Image vuln scan (bonus) | n/a | Azure Portal → ACR → **Microsoft Defender → Recommendations** — if Defender for Containers is enabled, the new image gets a vuln scan within minutes; attach that to the audit report |
| Container Insights audit | n/a | Azure Portal → AKS → **Monitoring → Logs** — KQL: `KubeEvents | where ObjectKind == "ClusterPolicy"` — see when policy changed |
| The script's own report card | Printed inline at the end of the run | Same |

## Talking points to verify visually

- Open `cosign tree` against the image **before** the demo: only a signature
  referrer exists. After the demo: both signature and attestation referrers
  are attached to the image digest. The attestation manifest is a **DSSE
  envelope** wrapping the SLSA predicate — fetch it with
  `cosign download attestation` and you can read the JSON containing your
  real git SHA.
- The CISO report at the end of the script lists numbers (`Rekor tree size`,
  `PolicyReports`) that match what you'd see in Rekor's UI and what `kubectl
  get policyreport` would report. Have both open in side-by-side terminals
  during the talk.
- The report is a fixed-width box (78 columns) — give the terminal at least
  that width before presenting so the right border stays flush. The box pads by
  display column (not bytes), so the `✓` glyphs line up; the keyless **SAN URI**
  identity is printed on its own line so the full SPIFFE-style value is visible.
- The `predicateType` in the registry's attestation manifest is
  `https://slsa.dev/provenance/v0.2`. That's a **public standard URL** —
  unlike a proprietary attestation format, this is what GitHub Actions,
  Tekton Chains, etc. all emit, so the same downstream tools (`slsa-verifier`,
  `policy-controller`, etc.) work against it.

## minikube vs AKS notes

Almost identical to Demo 3:

| | minikube | AKS |
|---|----------|-----|
| `--certificate-oidc-issuer` (verify) | `https://kubernetes.default.svc` | `$AKS_OIDC_ISSUER_URL` |
| Registry shown in CISO report | `localhost:30500/demo/app:latest` | `<acr>.azurecr.io/demo/app:latest` |
| `image digest` computation | Reads `http://$REGISTRY/v2/.../manifests/latest` (plain HTTP works) | The plain-HTTP fetch will fail on AKS (ACR uses HTTPS + auth). The script falls back to `sha256:unknown` for the printed digest in the report, but the **actual signed digest** is still correct (it's whatever cosign signed). Use `docker manifest inspect <acr>.azurecr.io/demo/app:latest` for the precise digest. |
| PolicyReport count | Whatever your cluster has accumulated | Same |
| Demo "builder" id in predicate | Same on both — `https://github.com/actions/runner` (it's a demo predicate, not a real attestation) | Same |

## Cleanup

Nothing to clean — the attestation and Rekor entry are intentional, permanent
demo state. If you want a pristine cluster, run `bash scripts/uninstall.sh`
(minikube) or `bash scripts/aks-down.sh` (AKS).

## Troubleshooting

**`Error: no matching attestations`** during verify — usually means the
`--certificate-identity` or `--certificate-oidc-issuer` doesn't match what
Fulcio embedded in the attestation cert. On AKS, source `_cluster-detect.sh`
and confirm `$AKS_OIDC_ISSUER_URL`.

**`bundle does not contain a valid timestamp` / Rekor lookup fails** — the
Rekor port-forward dropped (common on macOS after sleep). Re-run
`bash scripts/port-forward.sh`.

**Git SHA reported as `unknown`** — the script is being run outside a git
checkout (or with `git` not on PATH). Cosmetic only; the attestation is
still cryptographically valid.

**The attestation doesn't show up as a referrer** — `cosign attest`
silently uses the registry credentials in `~/.docker/config.json`. On AKS
re-run `az acr login -n $ACR_NAME` and retry. Confirm with
`cosign tree "$ACR_LOGIN_SERVER/demo/app:latest"`.
