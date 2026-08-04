# Demo 4 — CI/CD Pipeline Simulation

## Prerequisites

- Stack deployed: `bash scripts/install.sh` (minikube or AKS) completed.
- Port-forwards running (automatic via `install.sh`) or ACR reachable on AKS.
- **`build-and-push.sh` is NOT needed** — Demo 4 builds and pushes the demo
  image itself as part of the simulated pipeline (BUILD → PUSH → SIGN steps).
- A container build tool on PATH: one of `docker`, `podman`, or `minikube`
  (auto-detected).

## What this demo shows

A simulated GitHub Actions pipeline as five shell steps that mirror a real
workflow: **BUILD → PUSH → SIGN (×2) → VERIFY → DEPLOY**. The image is rebuilt
with metadata baked in (`GIT_SHA`, `BUILD_TIME`), pushed to the cluster's
registry, signed with **both** Smallstep CA *and* Sigstore keyless paths, both
signatures are verified by `cosign`, and finally a `Deployment` (named
`demo-app-signed`) is applied — passing through Kyverno's admission webhook
because the image is properly signed.

Run it with:

```bash
bash demos/demo4-cicd/run.sh
```

## What changes when the script runs

| Scope | Effect | Persists? |
|-------|--------|-----------|
| Container registry | Re-pushes `demo/app:latest` with the **current** git SHA + build time as build args (so the manifest digest changes); attaches a Smallstep signature **and** a Sigstore signature, each as an OCI 1.1 referrer of the new image digest | **Yes** for the new image + signatures |
| step-ca | Issues one 5-minute Code-Signing cert | Audit log entry (kept) |
| Fulcio | Issues one 10-minute keyless cert | Embedded in the signature manifest |
| Rekor | Appends **two** entries (one per signing path); `treeSize` grows by 2 | **Yes** |
| Kubernetes | Creates `Deployment/demo-app-signed` in namespace `workload` (1 replica, `imagePullPolicy: Always` so `:latest` re-pulls each run); waits for `kubectl rollout status` | **Yes** — left running so you can `kubectl get deployment -n workload` after the demo |
| Kyverno | Generates a `PolicyReport` entry in namespace `workload` recording the admission decision (PASS, signature verified) | **Yes** |
| Filesystem | `/tmp/demo4-cicd-XXXXXX/` (cert, key, chain) | **No** |

The Deployment is intentionally left running — your audience can point at
`kubectl get deployment -n workload` to confirm Kyverno admitted the signed
image. The next run of this script (or Demo 5) deletes the stale one at
start.

## How to verify (CLI)

### 1. Image digest changed and is in the registry

```bash
# Before/after digest:
crane manifest "${REGISTRY:-localhost:30500}/demo/app:latest" 2>/dev/null | sha256sum
# Or simpler:
docker manifest inspect "${REGISTRY:-localhost:30500}/demo/app:latest" 2>/dev/null | jq .config.digest
```

### 2. Two new signatures are attached

```bash
cosign tree --allow-insecure-registry "${REGISTRY:-localhost:30500}/demo/app:latest"
# Expect at least 2 Signatures entries (Smallstep + Sigstore from this run,
# plus any from previous runs of Demos 2 and 3).
```

### 3. Two new Rekor entries

```bash
# Watch the tree size before/after the demo:
curl -s "${REKOR_URL:-http://localhost:30300}/api/v1/log" | jq .treeSize
```

### 4. Independent verify of the keyless signature

```bash
ISSUER=${AKS_OIDC_ISSUER_URL:-https://kubernetes.default.svc}
cosign verify \
  --certificate-identity "https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa" \
  --certificate-oidc-issuer "$ISSUER" \
  --allow-insecure-registry --insecure-ignore-sct=true \
  "${REGISTRY:-localhost:30500}/demo/app:latest"
```

### 5. Deployment landed and was admitted by Kyverno

```bash
kubectl get deploy demo-app-signed -n workload                   # (visible while script is running)
kubectl describe deploy demo-app-signed -n workload | head -40
kubectl get policyreport -n workload -o yaml | \
  grep -A2 "demo-app-signed"
# Expect: result: pass, message: image verified
```

### 6. Confirm the running pod was scheduled from a verified image

```bash
kubectl get pods -n workload -l app=demo-app-signed -o yaml | \
  grep -A2 "containerStatuses:" | grep imageID
# Expect imageID with sha256:<digest> matching the one cosign signed
```

### 7. Confirm the image was pulled via the right route

```bash
# minikube: pulled via the in-cluster registry service DNS
kubectl describe pod -n workload -l app=demo-app-signed | grep -E "Image:|Pulled"
#   minikube: image registry.registry.svc.cluster.local:5000/demo/app:latest
#   AKS:      image <acr>.azurecr.io/demo/app:latest

# On AKS, also confirm kubelet UAMI has AcrPull:
KUBELET=$(az aks show -g "$AKS_RG" -n "$AKS_CLUSTER" \
  --query identityProfile.kubeletidentity.objectId -o tsv)
az role assignment list --assignee "$KUBELET" --scope $(terraform -chdir=infra/aks output -raw acr_id) \
  --query "[].roleDefinitionName" -o tsv     # expect: AcrPull
```

## How to verify (visual UIs)

| UI | minikube | AKS |
|----|----------|-----|
| Pipeline progress | The script itself uses GH-Actions-style `▶ [STEP]` / `✓` markers in the terminal | Same |
| Image in registry | `cosign tree http://localhost:30500/demo/app:latest` — look for new `via OCI referrer` lines under each digest | Azure Portal → ACR → **Repositories → demo/app** → click the image digest → **Referrers** tab |
| Image vulnerabilities (AKS only) | n/a | Azure Portal → ACR → **Microsoft Defender** tab (if enabled) — scans the new image automatically |
| Deployment status | `minikube dashboard` → namespace `workload` → `demo-app-signed` — watch it go from Pending → Running | Azure Portal → AKS → **Workloads** → filter ns `workload` → `demo-app-signed` Deployment → live status |
| Pod logs | Dashboard → pod → **Logs** | Same path in Azure Portal |
| Kyverno admission decision | Dashboard → `policy/kyverno-admission-controller-*` → **Logs** — search for `demo-app-signed` | Azure Portal → AKS → Workloads → ns `policy` → kyverno-admission-controller → **Logs** |
| PolicyReport view | `kubectl get policyreport -n workload -o wide` (no first-class GUI) | Same. Bonus on AKS: **Container Insights** → **Live data (preview)** shows admission events |
| Rekor tree | <http://localhost:30300/api/v1/log> — `treeSize` +2 after demo | Same via port-forward |

## Talking points to verify visually

- Open the registry referrers list in a browser **before** running. You'll
  see exactly one signature referrer (from Demo 2/3) attached to the image
  digest. Refresh after — the manifest digest has changed because Demo 4
  rebuilt the image, and the new digest carries two new signature referrers
  (Smallstep + Sigstore).
- In the Kyverno admission controller logs, the line for `demo-app-signed`
  should show `image verified` (verify mode = Audit at this point — Demo 5
  will switch it to Enforce).
- Stream the deployment status in the dashboard while the script runs:
  the rollout completes in ~10 seconds because the image is already cached
  on the node (it was just pushed by the same script).
- In Rekor, the two new entries have different `kind` values: the Smallstep
  one is `hashedrekord` with a static cert chain; the Sigstore one is
  `hashedrekord` with a Fulcio-issued cert. Click into each and decode the
  `body` field to see the difference.

## minikube vs AKS notes

Demo 4 is the most cluster-aware of all the demo scripts. Key branches:

| Step | minikube | AKS |
|------|----------|-----|
| BUILD | `minikube image build -t $IMAGE demos/demo-app/` (uses the in-VM containerd) | `docker build` (or `podman build`) on the host |
| PUSH  | `minikube ssh -- sudo ctr push --plain-http $REGISTRY_CLUSTER_IP:5000/...`, then a second `ctr tag` so the in-cluster DNS name works | `az acr login -n $ACR_NAME` + `docker push <acr>.azurecr.io/demo/app:latest` |
| DEPLOY → `image:` | `registry.registry.svc.cluster.local:5000/demo/app:latest` (`$CLUSTER_REGISTRY`) | `<acr>.azurecr.io/demo/app:latest` |
| VERIFY → `--certificate-oidc-issuer` | `https://kubernetes.default.svc` | `$AKS_OIDC_ISSUER_URL` |

The script auto-detects the right branch via `_cluster-detect.sh`. The
verification step always uses the **host** registry URL (`$REGISTRY`) because
that's where `cosign` connects from; the Deployment always uses
`$CLUSTER_REGISTRY` because that's the in-cluster pull path.

## Cleanup

The `trap cleanup EXIT` handler only removes the temp directory. The
`demo-app-signed` Deployment, the image, signatures, Rekor entries, and
PolicyReport entry are intentionally left in place — they're real artefacts
that demonstrate the pipeline ran, and the audience can inspect them on
stage. Stale Deployment objects are pre-cleaned at the start of the next
run so re-runs are idempotent.

If you need to manually clean up:

```bash
kubectl delete deploy demo-app-signed -n workload --ignore-not-found
# Signatures and Rekor entries are append-only and cannot (and should not)
# be deleted. Re-running scripts/install.sh --upgrade will leave them alone.
```

## Troubleshooting

**`failed to verify image` in Kyverno logs** during the DEPLOY step usually
means the image digest pushed in PUSH differs from the digest signed in SIGN.
This can happen if you have multiple tags pointing at different content.
Re-run the demo end-to-end — `--use-signing-config=false` plus the same
local `$IMAGE` reference means the script always signs the image it just
pushed.

**`x509: certificate signed by unknown authority`** on AKS — your local
docker daemon doesn't trust the ACR cert chain. Run `az acr login -n $ACR_NAME`
again.

**`pod has unbound immediate PersistentVolumeClaims`** — unrelated to this
demo; the demo-app uses no PVC. Check `kubectl get pods -A -o wide` for
other workloads competing for storage.
