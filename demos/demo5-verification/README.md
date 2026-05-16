# Demo 5 — Verification as a Policy Gate (Kyverno Enforce mode)

## Prerequisites

- Stack deployed: `bash scripts/install.sh` (minikube or AKS) completed.
- Port-forwards running (automatic via `install.sh`) or ACR reachable on AKS.
- **`build-and-push.sh` is NOT needed** — Demo 5 builds its own intentionally
  unsigned `busybox`-based image to demonstrate Kyverno blocking unsigned
  workloads.
- The `require-image-signature` ClusterPolicy must be installed (applied
  automatically by `install.sh` after Kyverno is Ready; verify with
  `kubectl get clusterpolicies`).

## What this demo shows

The "moment of truth" demo: Kyverno's `ClusterPolicy/require-image-signature`
is patched to use the **local Sigstore infrastructure** (Fulcio root cert,
Rekor public key, the cluster-appropriate OIDC issuer), then flipped from
**Audit → Enforce**. An unsigned image is pushed to the registry and a
`kubectl run` attempts to launch it — Kyverno **blocks it at admission**.
A correctly signed image is then deployed and is **admitted**. The script
finishes by restoring Audit mode (idempotent cleanup).

Run it with:

```bash
bash demos/demo5-verification/run.sh
```

## What changes when the script runs

| Scope | Effect | Persists? |
|-------|--------|-----------|
| Kyverno ClusterPolicy `require-image-signature` | `spec.rules[0].verifyImages[0].attestors[0].entries[0].keyless` patched with the live Fulcio root cert, Rekor pubkey, and the OIDC issuer for the current cluster; `mutateDigest: true`; `validationFailureAction: Enforce` | **Reverted on exit** by `trap cleanup` |
| Container registry | Pushes a new repository `demo/unsigned:latest` (busybox-based, no signature) | **Yes** (intentional — leave it there for repeated runs) |
| `demo/app:latest` | Re-signed with `--new-bundle-format=false` (Kyverno v1.15 doesn't yet support cosign v3's newest bundle format) — attaches an additional signature manifest as an OCI 1.1 referrer of the image digest | **Yes** |
| Rekor | One new entry from the re-signing step; `treeSize` +1 | **Yes** |
| Kubernetes | Attempts a `Pod/unsigned-test` in `workload` (expected: **rejected by webhook, never created**); creates `Deployment/signed-test` in `workload` (1 replica, `imagePullPolicy: Always`) | `signed-test` **left running** for audience inspection; the failed `unsigned-test` pod is cleaned up on exit |
| Kyverno | Generates `PolicyReport` entries for both attempts — pass for `signed-test`, fail for `unsigned-test` | **Yes** |
| containerd mirror config (minikube only) | Writes `/etc/containerd/certs.d/registry.registry.svc:5000/hosts.toml` inside the minikube VM so the kubelet can resolve the in-cluster DNS name to the registry ClusterIP | **Yes** (in the VM) |

## How to verify (CLI)

### 1. Confirm the policy is now in Enforce mode (while the script is between steps)

```bash
kubectl get clusterpolicy require-image-signature -o yaml | \
  grep -E "validationFailureAction|mutateDigest"
# Expect during the demo:
#   validationFailureAction: Enforce
#   mutateDigest: true
# After script exits:
#   validationFailureAction: Audit
#   mutateDigest: false
```

### 2. Confirm the keyless config carries the live Fulcio root + Rekor key

```bash
kubectl get clusterpolicy require-image-signature -o json | \
  jq '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keyless | {issuer, subject, rekor: .rekor.url, has_root_pem: (.roots | startswith("-----BEGIN"))}'
# Expect:
#   issuer:     https://kubernetes.default.svc   (minikube) OR https://...oic.prod-aks... (AKS)
#   subject:    https://kubernetes.io/namespaces/workload/serviceaccounts/signing-sa
#   has_root_pem: true
```

### 3. Watch the unsigned image get rejected at admission

```bash
# Re-run the rejected step manually while the policy is in Enforce mode
# (during Step 4 of the script, before cleanup runs):
kubectl run repro-unsigned -n workload \
  --image="${CLUSTER_REGISTRY:-registry.registry.svc.cluster.local:5000}/demo/unsigned:latest" \
  --restart=Never --command -- sleep 3600 2>&1 | head
# Expect:
# Error from server: admission webhook "mutate.kyverno.svc" denied the request:
#   failed to verify image ...demo/unsigned:latest: no matching signatures
kubectl get pod repro-unsigned -n workload    # should be: not found
```

### 4. Watch the signed image get admitted

```bash
kubectl get deploy signed-test -n workload
kubectl get pods -n workload -l app=signed-test
kubectl describe deploy signed-test -n workload | grep -A5 Conditions
# Expect Available=True within ~30s
```

### 5. Inspect the PolicyReports

```bash
# minikube and AKS both:
kubectl get policyreport -n workload
kubectl get policyreport -n workload -o json | \
  jq '.items[].results[] | {policy, rule, result, message: .message[:80]}'
# Expect entries with result=pass for signed-test, result=fail for unsigned-test
```

### 6. Confirm cleanup restored Audit mode

After the script exits:

```bash
kubectl get clusterpolicy require-image-signature -o jsonpath='{.spec.validationFailureAction}'
# Expect: Audit
kubectl get pod unsigned-test signed-test -n workload --ignore-not-found
# Expect: nothing
```

## How to verify (visual UIs)

| UI | minikube | AKS |
|----|----------|-----|
| Live admission decisions | `kubectl get events -n workload --watch` in a side terminal — see `FailedCreate` events for `unsigned-test` | Same, plus Azure Portal → AKS → **Events** (filter ns=workload) |
| Pod attempt timeline | `minikube dashboard` → ns `workload` → **Events** column shows the rejected `unsigned-test` | Azure Portal → AKS → **Workloads** → **Events** tab |
| Kyverno admission controller logs | Dashboard → ns `policy` → `kyverno-admission-controller-*` → **Logs** — search for `denied` | Azure Portal → AKS → Workloads → ns `policy` → kyverno → **Logs**; or `kubectl logs -n policy ... -f` |
| PolicyReports browser | k9s or `kubectl get policyreport -n workload -o yaml` (no UI) | **Azure Policy** blade in the Portal does *not* show Kyverno policies — they're CRDs, view via kubectl |
| Registry — unsigned image vs signed image | `cosign tree` against each: `demo/app` shows OCI signature referrers; `demo/unsigned` shows none | Azure Portal → ACR → **Repositories** — both repos have a `latest` tag, but only `demo/app`'s image digest has entries under its **Referrers** tab |
| Rekor diff | <http://localhost:30300/api/v1/log> — `treeSize` +1 (only the re-sign of `demo/app`, not the unsigned image) | Same |

## Talking points to verify visually

- Have `kubectl get events -n workload --watch` running on a second screen.
  When the unsigned image attempt fires, you get an immediate event with
  message `admission webhook ... denied the request: ... no matching signatures`.
  This is the **single most impactful** thing to point at for a security
  audience.
- In the registry browser, deliberately compare the two repos via `cosign
  tree`: `demo/app`'s image digest has signature referrers attached;
  `demo/unsigned`'s does not. That asymmetry is what Kyverno is checking.
- In the Kyverno admission controller log, the rejection line includes the
  fully-rendered image reference **with digest** (Kyverno performs
  tag→digest resolution before policy evaluation thanks to `mutateDigest: true`).

## minikube vs AKS notes

The flow is identical; three target-specific branches in the script:

| Step | minikube | AKS |
|------|----------|-----|
| Unsigned-image push | `minikube image build` + `minikube ssh -- ctr push --plain-http` | `az acr login -n $ACR_NAME` + `docker build/push` |
| containerd cert mirror config | Written into the minikube VM so the in-cluster DNS name (`registry.registry.svc:5000`) resolves to the registry ClusterIP | Not needed — kubelet uses ACR via the UAMI's AcrPull |
| `keyless.issuer` in ClusterPolicy patch | `https://kubernetes.default.svc` | `$AKS_OIDC_ISSUER_URL` |

A unique gotcha on AKS: the Kyverno admission controller's network egress
must reach the in-cluster Rekor and Fulcio (it does — they're all CIIs in
the same cluster) **and** must trust the OIDC issuer URL (which is
public — `oic.prod-aks.azure.com`). The chart's Fulcio config rendered by
`aks-up.sh` already lists both issuers, but if you re-create the cluster
the issuer URL changes and the ClusterPolicy will start failing
verification until the script re-patches it — re-run `bash scripts/install.sh`
and then re-run Demo 5.

## Cleanup

Automatic, via `trap cleanup EXIT`. Specifically:

1. Reverts `mutateDigest` to `false` (must happen first — Kyverno rejects
   the `Audit` switch while `mutateDigest: true`).
2. Reverts `validationFailureAction` to `Audit`.
3. Deletes the failed `unsigned-test` pod.

The `signed-test` Deployment is **intentionally left running** so your
audience can `kubectl get deployment -n workload` after the demo and see
the Kyverno-admitted pod. The next run of this script pre-cleans it.

Manual rollback if cleanup didn't run (e.g. `kill -9`):

```bash
kubectl patch clusterpolicy require-image-signature --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/verifyImages/0/mutateDigest","value":false}]'
kubectl patch clusterpolicy require-image-signature \
  --type=merge -p '{"spec":{"validationFailureAction":"Audit"}}'
kubectl delete deploy signed-test -n workload --ignore-not-found
kubectl delete pod unsigned-test -n workload --ignore-not-found
```

## Troubleshooting

**`policy invalid: spec.rules[0].verifyImages[0].mutateDigest: ... requires Enforce`**
— you tried to set `mutateDigest: true` while `validationFailureAction: Audit`.
The script orders these correctly; if you patched manually, reverse the order.

**`failed to verify image ... no matching signatures`** when you expected a PASS
— check the `keyless.issuer` matches what `cosign verify` accepts for the same
image. The two must agree. Re-run `bash scripts/install.sh` (it re-renders
`values-aks.local.yaml` and re-applies the chart).

**Unsigned-image push fails on AKS** — `az acr login` token expired. Run
`az acr login -n $ACR_NAME` and re-run the demo.
