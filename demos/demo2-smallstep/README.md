# Demo 2 — Smallstep CA Signing Path

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

The "private PKI" signing path: a short-lived (2-minute) X.509 certificate is
issued by the in-cluster **step-ca**, used by `cosign` to sign
`demo/app:latest`, and then **deliberately allowed to expire** before the
verification step. The point: the signature still verifies, because the cert
was valid at signing time and Rekor recorded the exact signing timestamp.

Run it with:

```bash
bash demos/demo2-smallstep/run.sh
```

Total runtime ~4 minutes (most of which is a 130-second wait for the cert to
expire).

## What changes when the script runs

| Scope | Effect | Persists after script exits? |
|-------|--------|------------------------------|
| step-ca (in-cluster) | Issues one cert from the `workload-signer` JWK provisioner; ~5 KB tlog entry on the CA's audit DB | **Yes** (the CA never deletes audit records) |
| Container registry | Adds an OCI 1.1 signature referrer (a separate manifest with `subject:` pointing at the image digest). Discover with `cosign tree` or the ACR Portal **Referrers** tab — there is no `.sig` tag in cosign v3. | **Yes** (you'll see it from now on in `cosign tree`) |
| Rekor | Appends one entry (kind: `hashedrekord`, with the Smallstep-issued cert embedded) → `treeSize` increments by 1 | **Yes** (Rekor is append-only) |
| Filesystem | `/tmp/demo2-smallstep-XXXXXX/` with the cert, private key, chain, trusted-root | **No** (cleaned by `trap`) |
| Kubernetes objects | None directly — but the in-cluster step-ca pod logs the issuance | n/a |

## How to verify (CLI)

### 1. Confirm step-ca issued the cert correctly

```bash
# While the script is paused on the "Step 3: Inspect the certificate" header,
# or by re-running the same step ca certificate request yourself:
openssl x509 -in /tmp/demo2-smallstep-*/cert.pem -noout \
  -subject -issuer -dates -ext extendedKeyUsage
# Expect:
#   subject= CN = demo2-signing-key
#   issuer=  CN = DevSecOps Demo CA Intermediate CA
#   notBefore/notAfter spans only ~2 minutes
#   X509v3 Extended Key Usage: Code Signing
```

### 2. Confirm the signature landed in the registry

```bash
cosign tree --allow-insecure-registry "${REGISTRY:-localhost:30500}/demo/app:latest"
# Expect a "Signatures" / "via OCI referrer" line for the image digest.
```

### 3. Confirm the Rekor tlog entry exists

```bash
# Capture the tree size before AND after the demo:
curl -s "${REKOR_URL:-http://localhost:30300}/api/v1/log" | jq .treeSize
# Should be exactly +1 after Demo 2 runs (more if you also ran Demo 3/4/6).
```

### 4. Reproduce the post-expiry verify the script does

The most interesting verification is the post-expiry one. The script builds a
custom Sigstore "trusted root" JSON (because we're using private CA + private
Rekor) and passes it via `--trusted-root`. To reproduce:

```bash
TMP=/tmp/demo2-smallstep-*    # match the leftover dir if script paused, or rebuild
cosign verify \
  --trusted-root "$TMP/trusted-root.json" \
  --certificate-identity-regexp '.*' \
  --certificate-oidc-issuer-regexp '.*' \
  --allow-insecure-registry \
  --insecure-ignore-sct=true \
  "${REGISTRY:-localhost:30500}/demo/app:latest"
# Expect: "Verified OK" even though `openssl x509 ... -checkend 0` rejects the cert.
```

### 5. step-ca audit trail

```bash
# Smallstep records every certificate it issues — pull a fresh count:
kubectl logs -n pki -l app.kubernetes.io/name=step-certificates \
  --tail=200 | grep -c 'sign certificate'
# Increases by 1 for every Demo 2 run.
```

## How to verify (visual UIs)

| UI | minikube | AKS |
|----|----------|-----|
| step-ca health page | <https://localhost:39000/health> (accept the self-signed cert) | Same — port-forwarded by `scripts/port-forward.sh` |
| Registry signatures | `cosign tree http://localhost:30500/demo/app:latest` — look for the `via OCI referrer` line under the image digest | Azure Portal → ACR → **Repositories → demo/app** → click the image **digest** → **Referrers** tab shows the new signature manifest |
| Cluster pods | `minikube dashboard` → **pki** namespace → `step-certificates-0` → **Logs** tab — see the "sign certificate" event | Azure Portal → AKS → **Workloads** → filter namespace `pki` → `step-certificates-0` → **Logs** |
| Rekor tree size | <http://localhost:30300/api/v1/log> (JSON in browser) — refresh and watch `treeSize` increment | Same URL via port-forward |
| Rekor entry detail | <http://localhost:30300/api/v1/log/entries?logIndex=N> (use the index printed by the script) | Same |
| Smallstep dashboard (optional) | `kubectl port-forward -n pki svc/step-certificates 9000:9000` then browse <https://localhost:9000> | Same |

In the **registry view**, the signature is an **OCI 1.1 referrer** of the
image manifest — a separate artefact whose `subject:` field points at the
image digest. In the ACR Portal, click the image digest (not the `latest`
tag) and open the **Referrers** tab to see the cert and signature blobs in
its manifest body.

## Talking points to verify visually

- Open Rekor's `/api/v1/log` JSON in a browser **before** running the demo,
  note the `treeSize` and `rootHash`. Refresh after — both have changed, and
  the new `rootHash` is mathematically committed to all prior entries
  (Merkle tree property).
- In the registry UI, copy the signature manifest. The blob it references
  contains the Smallstep cert chain you can decode with `openssl x509 -text`.
- The pod `step-certificates-0` in namespace `pki` has logs that mention the
  exact SAN (`signing@demo.local`) — visible in the K8s dashboard.

## minikube vs AKS notes

The flow is identical on both targets. Key differences:

- **Port-forwards required on AKS**: `step-ca`, Rekor, TUF, Fulcio are
  ClusterIP-only on AKS. `scripts/port-forward.sh` exposes them at the same
  localhost ports the script uses (`30100`/`30200`/`30300`/`30500`/`39000`).
- **Image reference**: `IMAGE` is auto-detected — `localhost:30500/demo/app:latest`
  on minikube, `<acr>.azurecr.io/demo/app:latest` on AKS.
- **Cert content is identical** on both — the CA is in-cluster and target-agnostic.
- **Rekor tree on AKS is fresh per `aks-up.sh`**: tearing down the cluster
  resets the transparency log. Don't be alarmed if `treeSize` starts at 1.

## Cleanup

Automatic. The signature artefact in the registry is **left in place**
intentionally — Demos 3/4/5/6 build on top of it.

## Troubleshooting

If Step 2 ("Request a short-lived signing certificate") fails with
`connection refused`, your port-forward for step-ca isn't running:

```bash
bash scripts/port-forward.sh
curl -sk https://localhost:39000/health   # expect {"status":"ok"}
```

If the post-expiry verify fails with `certificate expired`, your local clock
has drifted more than the 10-second buffer the script allows — re-sync NTP
and retry.
