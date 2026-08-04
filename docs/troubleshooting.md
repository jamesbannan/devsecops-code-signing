# Troubleshooting

Quick check before digging in:

```bash
bash scripts/verify.sh   # Runs all 18 checks with [PASS]/[FAIL]/[WARN] output
kubectl get pods -A      # Check for CrashLoopBackOff, Pending, or OOMKilled pods
```

---

## 1. OIDC issuer mismatch — Fulcio rejects token

**Symptom:**
```
cosign sign: error getting Fulcio SCTs: ...
error fetching OIDC token: invalid issuer claim
# Or, server-side, in fulcio-server logs:
# "There was an error processing the identity token"
```

Or `scripts/verify.sh` Check 13 fails with an unexpected issuer URL.

**Cause (minikube):**
minikube was started without the `--extra-config=apiserver.service-account-issuer` flag,
so the Kubernetes API server uses an auto-generated issuer URL that Fulcio cannot validate.

**Fix (minikube):**
```bash
minikube stop
bash scripts/start-minikube.sh

# Verify:
kubectl get --raw /.well-known/openid-configuration | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
# Expected: https://kubernetes.default.svc
```

**Cause (AKS):**
Fulcio's `OIDCIssuers` config doesn't include the AKS-managed issuer URL, or `chart/values-aks.local.yaml` was not rendered before `helm install` ran. The AKS issuer looks like `https://<region>.oic.prod-aks.azure.com/<tenant-guid>/<cluster-guid>/`.

**Fix (AKS):**
```bash
# Confirm the live issuer and ensure it is in the rendered values file:
terraform -chdir=infra/aks output -raw oidc_issuer_url
grep -A2 OIDCIssuers chart/values-aks.local.yaml

# If missing, re-render and re-upgrade:
bash scripts/aks-up.sh           # idempotent — re-renders values-aks.local.yaml
helm upgrade devsecops-demo chart/ -f chart/values-aks.local.yaml --wait
# Fulcio configmap-only changes require a pod restart:
kubectl rollout restart deploy/fulcio-server -n fulcio-system
```

> **Note:** the Fulcio sub-chart consumes `scaffold.fulcio.config.contents` as a complete
> JSON blob (Pascal-case keys: `OIDCIssuers`, `IssuerURL`, `ClientID`, `Type`). The
> chart's `OIDCIssuers` list intentionally contains **both** the AKS issuer and
> `https://kubernetes.default.svc` so the same configuration works on either target.

---

## 2. TUF root not initialised — cosign can't verify

**Symptom:**
```
cosign verify: TUF root not found in $HOME/.sigstore
error initializing TUF: ...
```

**Cause:**
cosign requires its TUF root to be bootstrapped before any signing or verification operations. This is done against the local TUF mirror (if using the self-hosted Sigstore stack).

**Fix:**
```bash
# Re-initialize cosign TUF root against the local mirror
cosign initialize \
  --mirror http://localhost:30100 \
  --root http://localhost:30100/root.json

# If TUF is not reachable, check the port-forward:
bash scripts/port-forward.sh
kubectl get pods -n tuf-system
```

**In-cluster jobs:**
The signing jobs call `cosign initialize` as the first command. If TUF is not ready when the job runs, it will fail and retry (backoffLimit: 2). Wait for TUF to become ready:
```bash
kubectl rollout status deployment/tuf -n tuf-system --timeout=5m
```

---

## 3. Registry push fails — insecure registry not trusted

**Symptom:**
```
podman push: Error: ... x509: certificate signed by unknown authority
# or
cosign sign: error signing: ... server gave HTTP response to HTTPS client
```

**Cause:**
The local registry at `localhost:30500` is HTTP (no TLS). Both Podman and cosign need to be told to allow this.

**Fix for Podman:**
```bash
# Push with TLS verification disabled
podman push --tls-verify=false localhost:30500/demo/app:latest

# Or add to /etc/containers/registries.conf (persistent):
[[registry]]
location = "localhost:30500"
insecure = true
```

**Fix for cosign:**
```bash
# All cosign commands targeting the local registry need this flag:
cosign sign --allow-insecure-registry localhost:30500/demo/app:latest
cosign verify --allow-insecure-registry localhost:30500/demo/app:latest
```

**For minikube (containerd):**
The `--insecure-registry="localhost:30500"` flag in `start-minikube.sh` configures containerd to trust the insecure registry. If you see pull failures in pods, the cluster may not have been started with this flag — restart with `bash scripts/start-minikube.sh`.

---

## 4. step-ca not ready — signing job can't get cert

**Symptom:**
```
signing-job-smallstep: Error: step ca certificate: ... connection refused
# or
ca-root-propagator: Waiting for step-certificates Secret... (stuck)
```

**Cause:**
step-ca takes 30–60 seconds to initialise after the chart is installed. The signing job may run before step-ca is ready.

**Diagnosis:**
```bash
kubectl get pods -n pki
kubectl logs -n pki -l app.kubernetes.io/name=step-certificates --tail=50

# Check the CA health
curl -sk https://localhost:39000/health
# Expected: {"status":"ok"}
```

**Fix:**
Wait for step-ca to be ready, then re-trigger the signing job:
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=step-certificates -n pki --timeout=5m

# Re-trigger the signing job
kubectl delete job signing-job-smallstep -n workload --ignore-not-found=true
kubectl apply -f chart/templates/workload/signing-job-smallstep.yaml
```

---

## 5a. Kyverno webhook race during install — `no endpoints available for service ...kyverno-svc`

**Symptom (during `scripts/install.sh`, most often on AKS cold starts):**
```
Error: failed post-install: warning: Hook post-install
devsecops-demo/templates/policy/cluster-image-policy.yaml failed:
Internal error occurred: failed calling webhook "mutate-policy.kyverno.svc":
failed to call webhook: Post "https://devsecops-demo-kyverno-svc.policy.svc:443/policymutate?timeout=10s":
no endpoints available for service "devsecops-demo-kyverno-svc"
```

**Cause:**
The `require-image-signature` ClusterPolicy was applied before Kyverno's
admission-controller pods registered any ready endpoints for
`devsecops-demo-kyverno-svc`. Helm hook weights only sequence among hooks —
they do not wait for regular chart resources (like Kyverno's Deployment)
to become Ready. With `--wait` deliberately omitted in `install.sh`
(demo workload Jobs would otherwise block), Helm fires the post-install
hook before Kyverno is admission-ready. AKS cold starts (~30–90s for
admission-controller pods) make the race almost certain; minikube usually
masks it.

**Fix (already applied in this repo):**
- `chart/templates/policy/cluster-image-policy.yaml` no longer uses
  `helm.sh/hook` annotations; it is gated behind
  `.Values.workload.policy.installClusterPolicy` (default `false`).
- `scripts/install.sh` adds the Kyverno admission-controller Deployment to
  its readiness wait list, then polls `endpoints/<release>-kyverno-svc`
  until populated, then runs a second
  `helm upgrade --reuse-values --set workload.policy.installClusterPolicy=true`
  to apply the policy.

**Recovery from a previously failed install (Helm release stuck in `failed` state):**
```bash
# Fast path — non-interactive forceful reset (cluster stays up):
bash scripts/cleanup.sh                            # interactive prompt
FORCE=true bash scripts/cleanup.sh                 # CI-friendly
FORCE=true PURGE_CRDS=true bash scripts/cleanup.sh # also drop demo CRDs

# Manual equivalent:
helm uninstall devsecops-demo -n pki --no-hooks    # --no-hooks avoids the
                                                   #   missing-webhook callback
bash scripts/install.sh                            # re-run installer
```

If a `helm uninstall` ever leaves namespaces in `Terminating` state because
orphan Kyverno `ValidatingWebhookConfigurations` block cluster-wide deletes,
`scripts/cleanup.sh` deletes those webhook configurations *first*, then
force-deletes pods/jobs/deployments, releases PVC finalizers, and (optionally)
purges CRDs. See **5b** below for the manual recipe.

If you ever need to apply the policy manually (e.g. you ran the chart with
your own `helm install`):
```bash
kubectl wait --for=condition=Available deployment/devsecops-demo-kyverno-admission-controller \
  -n policy --timeout=5m
# Wait for endpoints to populate (no native kubectl wait for endpoints presence):
until [ -n "$(kubectl get endpoints devsecops-demo-kyverno-svc -n policy \
  -o jsonpath='{.subsets[*].addresses[*].ip}')" ]; do sleep 5; done
helm upgrade devsecops-demo chart/ -n pki --reuse-values \
  --set workload.policy.installClusterPolicy=true
```

---

## 5. Kyverno webhook timeout — policy enforcement blocks everything

## 5b. Stuck namespaces / orphan Kyverno webhooks block all cluster deletes

**Symptom:**
After a partial install (or after `helm uninstall` is interrupted), you see:
```
Error from server (InternalError): Internal error occurred: failed calling
webhook "validate.kyverno.svc-fail": failed to call webhook: Post
"https://devsecops-demo-kyverno-svc.policy.svc:443/validate/fail?timeout=10s":
service "devsecops-demo-kyverno-svc" not found
```
…on *every* subsequent `kubectl delete`. Demo namespaces (e.g. `pki`,
`workload`, `rekor-system`) stay in `Terminating` indefinitely, and
`helm uninstall ... --no-hooks` errors with `release: not found` even
though pods remain.

**Cause:**
Kyverno's `ValidatingWebhookConfiguration` resources are cluster-scoped and
survive their namespace's deletion. They have `failurePolicy: Fail` and
point at `devsecops-demo-kyverno-svc.policy.svc`. Once that Service has no
ready endpoints (because the admission-controller pods or the entire `policy`
namespace are gone), every cluster-wide create/update/delete operation that
the webhook would intercept fails with the error above. Namespaces in
`Terminating` state can't drop their remaining objects → the cycle never
breaks.

**Fix (one-shot script):**
```bash
bash scripts/cleanup.sh                 # interactive
FORCE=true bash scripts/cleanup.sh      # non-interactive
```
The script (a) deletes the orphan Kyverno
`Validating`/`MutatingWebhookConfigurations` *first*, (b) runs
`helm uninstall --no-hooks`, (c) force-deletes pods/jobs/workloads
in every demo namespace, (d) patches out PVC finalizers, and
(e) clears namespace finalizers via the `/finalize` subresource for any
namespace still stuck after a configurable wait.

**Manual recovery (if the script is unavailable):**
```bash
# 1. Remove the orphan webhook configurations FIRST.
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o name | grep -i kyverno | xargs -r kubectl delete

# 2. Helm uninstall (now safe because webhooks won't intercept).
helm uninstall devsecops-demo -n pki --no-hooks || true

# 3. Force-delete remaining workloads in each demo namespace.
for ns in pki workload policy registry fulcio-system rekor-system \
          tuf-system trillian-system ctlog-system; do
  kubectl delete jobs,deployments,replicasets,statefulsets,pods \
    --all -n "$ns" --grace-period=0 --force --ignore-not-found
done

# 4. Release PVC finalizers (release the underlying disks).
for ns in pki registry rekor-system trillian-system; do
  for pvc in $(kubectl get pvc -n "$ns" -o name 2>/dev/null); do
    kubectl patch "$pvc" -n "$ns" --type=merge \
      -p '{"metadata":{"finalizers":null}}'
  done
done

# 5. If a namespace is still Terminating after a minute, clear its
#    own finalizer via the /finalize subresource (last resort).
for ns in $(kubectl get ns -o json | \
  jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name'); do
  kubectl get ns "$ns" -o json \
    | jq '.spec.finalizers=[]' \
    | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f -
done
```

**Prevention:**
Always run `bash scripts/cleanup.sh` (or `bash scripts/uninstall.sh`) instead
of `helm uninstall` alone, and never `kubectl delete ns policy` before the
Kyverno webhook configurations are gone.

---

## 5. Kyverno webhook timeout — policy enforcement blocks everything

**Symptom:**
```
kubectl apply: Error: Internal error occurred: failed calling webhook "mutate.kyverno.svc":
  ... context deadline exceeded
```

**Cause:**
Kyverno's admission webhook is unreachable (pods not ready, namespace deleted, or network issue). Kubernetes treats a webhook timeout as a blocking error if `failurePolicy: Fail` is set.

**Diagnosis:**
```bash
kubectl get pods -n policy
kubectl logs -n policy -l app.kubernetes.io/component=admissionController --tail=50
kubectl get validatingwebhookconfigurations | grep kyverno
```

**Fix:**
```bash
# Wait for Kyverno to be ready
kubectl rollout status deployment/kyverno-admission-controller -n policy --timeout=5m

# If Kyverno is stuck and blocking all admission (emergency):
# Delete the validating webhook configurations temporarily
# WARNING: this disables all Kyverno policy enforcement
kubectl delete validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg
# Then restart Kyverno and it will re-register its webhooks:
kubectl rollout restart deployment -n policy
```

---

## 6. Rekor tree not initialised — Trillian init job failed

**Symptom:**
```
cosign sign: error uploading tlog entry: ... tree is not initialised
# or Rekor pods in CrashLoopBackOff
```

**Cause:**
The Trillian MySQL init job failed, or the log tree was not created. This typically happens if MySQL takes too long to start.

**Diagnosis:**
```bash
kubectl get pods -n trillian-system
kubectl get jobs -n trillian-system
kubectl logs -n trillian-system -l app=trillian-logserver --tail=50

# Check if the tree exists
curl -s http://localhost:30300/api/v1/log | python3 -c "import sys,json; print(json.load(sys.stdin))"
```

**Fix:**
```bash
# Delete and re-run the Trillian create-tree job
kubectl delete job -n trillian-system -l app.kubernetes.io/component=createtree --ignore-not-found=true
# Then trigger a helm upgrade to re-run the job:
helm upgrade devsecops-demo chart/ --wait --timeout=10m
```

---

## 7. cosign verify fails after policy switch — cert identity mismatch

**Symptom:**
```
cosign verify: error: no matching signatures
# or
cosign verify: error: certificate identity mismatch
```

**Cause:**
`cosign verify` requires explicit `--certificate-identity` and `--certificate-oidc-issuer` flags in cosign v2. If these don't exactly match what's in the certificate, verification fails even if the signature is cryptographically valid.

**Diagnosis:**
```bash
# Inspect the actual certificate identity in the signature:
cosign verify --allow-insecure-registry \
  --certificate-identity-regexp ".*" \
  --certificate-oidc-issuer "https://kubernetes.default.svc" \
  localhost:30500/demo/app:latest | python3 -m json.tool
```

**Fix:**
Use the exact values from the certificate in your verify command:
```bash
# For Sigstore keyless (K8s SA identity):
cosign verify \
  --certificate-identity "system:serviceaccount:workload:signing-sa" \
  --certificate-oidc-issuer "https://kubernetes.default.svc" \
  --allow-insecure-registry \
  localhost:30500/demo/app:latest

# For Smallstep CA (certificate chain):
cosign verify \
  --certificate-chain /path/to/root_ca.crt \
  --certificate-identity-regexp ".*" \
  --allow-insecure-registry \
  localhost:30500/demo/app:latest
```

---

## 8. Port-forward dropped — common on macOS after sleep

**Symptom:**
```
curl: (7) Failed to connect to localhost port 30300: Connection refused
# or demo scripts fail with connection errors
```

**Cause:**
macOS suspends background processes during system sleep, killing `kubectl port-forward` processes. This is a known macOS behaviour, not a Kubernetes issue.

**Fix:**
```bash
# Re-run port-forward.sh — it automatically kills stale PIDs first
bash scripts/port-forward.sh

# Verify each service is reachable:
curl -s http://localhost:30300/api/v1/log | python3 -c "import sys,json; print('Rekor OK:', json.load(sys.stdin).get('treeSize'))"
curl -s http://localhost:30500/v2/     # Expected: {}
curl -s http://localhost:30200/healthz # Expected: ok
curl -s http://localhost:30100/root.json | python3 -c "import sys,json; print('TUF OK')"
curl -sk https://localhost:39000/health # Expected: {"status":"ok"}
```

**Prevention:**
On macOS, prevent sleep while the demo is running:
```bash
caffeinate -d &  # Prevents display sleep; kill it after the demo
```

---

## 9. Demo script exits silently mid-step (cosign v3 output parsing)

**Symptom:**
```
=== Step 2: Keyless signing — Fulcio issues the cert ===
...
$ cosign sign --fulcio-url ... --identity-token <token> ...
# (the script just stops here — no [OK], no [FAIL], exit code 1)
```
The image is actually signed successfully, but the demo aborts immediately
afterwards with no error message.

**Cause:**
cosign **v3** changed its signing output. It no longer prints
`tlog entry created with index: N` (or `SCT`) on `cosign sign` / `cosign attest`
— it only prints `Generating ephemeral keys… / Signing artifact… / Pushing
signature to:`. The demo scripts run under `set -euo pipefail`, so a
`grep 'index:'` (or `grep -E 'tlog|entry|SCT'`) that finds **no match** returns
exit 1, `pipefail` propagates it, and `set -e` kills the script — right after a
*successful* sign, which is why there is no obvious error.

**Diagnosis:**
```bash
cosign version   # GitVersion: v3.x.x

# Confirm the sign actually succeeded and the output no longer contains "index:":
TOKEN=$(kubectl create token signing-sa -n workload --audience=sigstore --duration=10m)
cosign sign --fulcio-url http://localhost:30200 --rekor-url http://localhost:30300 \
  --identity-token "$TOKEN" --allow-insecure-registry --use-signing-config=false --yes \
  localhost:30500/demo/app:latest
# -> "Pushing signature to: ..." but no "tlog entry created with index: N"
```

**Fix:**
The demo scripts read the tlog index from the **signature bundle** instead of
the sign output, and guard every output-parsing `grep` with `|| true`:
```bash
# cosign v3: the tlog index lives in the bundle, not the sign output
cosign download signature --allow-insecure-registry localhost:30500/demo/app:latest \
  | jq -r '.verificationMaterial.tlogEntries[].logIndex'
```
If you write your own scripts against cosign v3, never grep the sign/attest
stdout for `index:`/`tlog`/`SCT` under `set -e` without an `|| true` fallback.

---

## 10. `reset-demo.sh` helm upgrade fails — conflict with "kubectl-patch"

**Symptom:**
```
=== Redeploying workload Jobs (helm upgrade) ===
Error: UPGRADE FAILED: conflict occurred while applying object
  /require-image-signature kyverno.io/v1, Kind=ClusterPolicy:
  Apply failed with 2 conflicts: conflicts with "kubectl-patch" using kyverno.io/v1:
  - .spec.rules
  - .spec.validationFailureAction
  [WARN] helm upgrade reported errors
```

**Cause:**
Helm 4 uses **server-side apply** by default. Demo 5 runs
`kubectl patch clusterpolicy require-image-signature …` to flip
`validationFailureAction` to `Enforce` and `mutateDigest` to `true`. That makes
the `kubectl-patch` field manager the owner of `.spec.rules` /
`.spec.validationFailureAction`. When `reset-demo.sh` later runs `helm upgrade`,
Helm's server-side apply refuses to overwrite fields owned by a different manager
and fails with a conflict.

**Diagnosis:**
```bash
helm version --short    # v4.x → server-side apply by default

# See which field manager owns the policy's spec:
kubectl get clusterpolicy require-image-signature --show-managed-fields -o json \
  | jq '.metadata.managedFields[] | {manager, operation}'
# A "kubectl-patch" entry with operation "Update" owning .spec.rules is the culprit.
```

**Fix:**
`reset-demo.sh` already passes `--force-conflicts`, which tells server-side apply
to take ownership and reset the policy to the chart defaults
(`Audit`, `mutateDigest: false`) — exactly what a reset should do:
```bash
helm upgrade devsecops-demo chart/ -n pki --reuse-values --force-conflicts
```
If you hit this from a manual `helm upgrade` after running the demos, add
`--force-conflicts` yourself, or reset the policy first with
`bash scripts/reset-demo.sh`.

> **macOS note:** these scripts run via `#!/usr/bin/env bash`, and macOS ships
> bash 3.2 — so they avoid bash 4 syntax such as `${var,,}` (which raises
> `bad substitution`). Lowercasing is done with `tr '[:upper:]' '[:lower:]'`.

---

## 11. Demo fails with "connection refused" on localhost:39000 after a reset

**Symptom:**
After `bash scripts/reset-demo.sh`, the next demo that talks to step-ca (e.g.
Demo 2, Step 2) fails immediately:
```
=== Step 2: Request a short-lived signing certificate ===
client GET https://localhost:39000/provisioners?limit=100 failed:
  dial tcp [::1]:39000: connect: connection refused
```

**Cause:**
The chart ships a `stepca-codesigning-config` Helm hook
(`post-install,post-upgrade`) that `kubectl rollout restart`s the step-ca
StatefulSet to apply the Code Signing EKU template. `reset-demo.sh` runs
`helm upgrade`, which re-fires that hook, so **step-ca is restarted on every
reset**. A `kubectl port-forward svc/devsecops-demo-stepca` does *not*
auto-reconnect when its backing pod is replaced — the forward process dies and
`localhost:39000` goes dark. (The other forwards target Deployments that aren't
rolled, so they survive.)

**Diagnosis:**
```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://localhost:39000/health   # 000 = dead
# The step-ca pod is newer than the port-forward:
kubectl get statefulset devsecops-demo-stepca -n pki \
  -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}{"\n"}'
```

**Fix:**
`reset-demo.sh` now re-establishes the port-forwards automatically after the
`helm upgrade` (when `/tmp/devsecops-pf.pids` shows they were in use), so the
next demo just works. If you hit a stale forward outside the reset flow, refresh
them manually:
```bash
bash scripts/port-forward.sh   # or: bash scripts/resume.sh
```

---

## 12. Demo 6 shows "No PolicyReports found in workload namespace"

**Symptom:**

Demo 6's audit-trail step — the closing "CISO report" — prints
`No PolicyReports found in workload namespace` instead of the expected table,
even though signed workloads are running and Kyverno is healthy.

**Cause:**

Kyverno's reports controller can settle into a state where it evaluates
policies normally — the logs show `image attestors verification succeeded` —
but never writes the PolicyReports. This has been observed on a **freshly
installed cluster** with nothing deleted by hand, so it is not simply a
side effect of debugging.

Restarting the workload does not help; the reports otherwise only reappear at
the next full background scan, which defaults to one hour.

Check that reporting is actually enabled before chasing anything else — it
should list `imageVerify`:

```bash
kubectl get deploy kyverno-reports-controller -n policy \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep enableReporting
# --enableReporting=validate,mutate,mutateExisting,imageVerify,generate
```

Deleting the reports by hand (`kubectl delete policyreport -n workload --all`)
produces the same symptom. Note that none of the demo or reset scripts do this:
`scripts/reset-demo.sh` deliberately leaves them alone, and `scripts/cleanup.sh`
removes the whole namespace (a fresh `install.sh` then regenerates everything).

**Fix — force an immediate resync:**

```bash
kubectl rollout restart deployment/kyverno-reports-controller -n policy
kubectl rollout status  deployment/kyverno-reports-controller -n policy --timeout=180s

# Reports reappear within about 90 seconds
kubectl get policyreport -n workload
```

Deployment-scoped reports land first and carry only the autogen audit rule.
The `check-image-signature` result — the one worth showing an audience — comes
with the Pod-scoped reports slightly later, so wait for that rather than for a
non-zero report count.

**Demo 6 handles this automatically.** If it finds no PolicyReports at startup
it triggers the resync in the background and, at the report step, waits for a
`check-image-signature` result to appear. The recovery therefore overlaps the
narration instead of stalling the demo. Set `DEMO6_NO_NUDGE=true` to disable.

**Related: `FAIL=1` on a correctly signed image**

You may see a report row like `demo-app-signed ... PASS=1 FAIL=1` with the
message `missing digest for <image>`. This is **not** a signature failure. The
chart ships the policy with `validationFailureAction: Audit`, and Kyverno
rejects `mutateDigest: true` unless the action is `Enforce`:

```
spec.rules[0].verifyImages[0].mutateDigest: Invalid value: true:
mutateDigest must be set to false for 'Audit' failure action
```

With `mutateDigest: false` the reports controller has no resolved digest to
record, so it logs `missing digest` even though the preceding log line reads
`image attestors verification succeeded`. Demo 5 switches the policy to Enforce
(where `mutateDigest: true` is permitted) and the same image verifies cleanly.
Demo 6 now prints the failing messages and this explanation inline rather than
leaving a bare `FAIL=1` on screen.

Do **not** try to "fix" this by deploying the image by digest. Kyverno resolves
cosign v3 OCI 1.1 referrer signatures only from a tagged reference; given a bare
`repo@sha256:...` it reports `no signatures found` for an image that is in fact
correctly signed.

---

## AKS-Specific Issues

### A1. `terraform apply` fails: VM SKU not allowed in region

**Symptom:**
```
SkuNotAvailable: The requested VM size 'Standard_D2s_v5' is not available in location 'australiaeast'
# or
SkuNotAvailable: ... not authorized for the subscription
```

**Cause:**
The default `node_vm_size` in `infra/aks/variables.tf` isn't enabled for your
subscription or region.

**Fix:**
```bash
# List SKUs your subscription can use in the target region:
az vm list-skus --location australiaeast --resource-type virtualMachines \
  --query "[?capabilities[?name=='vCPUs' && value=='2']].name" -o tsv | sort -u

# Override the variable:
cd infra/aks
echo 'node_vm_size = "Standard_D4s_v5"' >> terraform.tfvars
terraform apply
```

### A2. `kubectl` pull error: ACR 401 / `unauthorized: authentication required`

**Symptom:**
```
Failed to pull image "<acr>.azurecr.io/demo/app:latest": ... 401 Unauthorized
```

**Cause:**
The AKS kubelet User-Assigned Managed Identity is missing the `AcrPull` role on the ACR.
This is created by `infra/aks/main.tf` (`azurerm_role_assignment.acr_pull`); if you
provisioned ACR separately, the role binding is missing.

**Fix:**
```bash
ACR_ID=$(terraform -chdir=infra/aks output -raw acr_id 2>/dev/null \
  || az acr show -n "<acr-name>" --query id -o tsv)
KUBELET_OBJID=$(az aks show -g "<rg>" -n "<cluster>" \
  --query identityProfile.kubeletidentity.objectId -o tsv)
az role assignment create --assignee-object-id "$KUBELET_OBJID" \
  --assignee-principal-type ServicePrincipal --role AcrPull --scope "$ACR_ID"
```

For host-side push 401 errors, refresh the ACR token (expires after ~3 hours):
```bash
az acr login -n <acr-name>
```

### A3. `aks-up.sh` re-run produces a new OIDC issuer URL

**Symptom:**
Demos 3/4/5/6 start failing after re-running `aks-up.sh` against a destroyed cluster.

**Cause:**
The AKS OIDC issuer is generated per cluster. A new cluster has a new issuer URL,
and the previously-installed Fulcio configmap still lists the old one.

**Fix:**
```bash
bash scripts/aks-up.sh           # re-renders chart/values-aks.local.yaml
helm upgrade devsecops-demo chart/ -f chart/values-aks.local.yaml --wait
kubectl rollout restart deploy/fulcio-server -n fulcio-system
```

### A4. Wrong `kubectl` context — commands hit minikube instead of AKS (or vice versa)

**Symptom:**
`scripts/_cluster-detect.sh` reports the wrong `CLUSTER_KIND`; demos use the wrong
registry.

**Fix:**
```bash
kubectl config get-contexts
kubectl config use-context <minikube | aks-context-name>
# Re-source the helper to refresh exported variables:
source scripts/_cluster-detect.sh
echo "$CLUSTER_KIND $REGISTRY"
```

### A5. Idle AKS cost — forgot to tear down

`aks-down.sh` runs `terraform destroy` in `infra/aks/` (also best-effort
`helm uninstall`). Run it whenever you're done — the cluster + ACR Premium accrue
charges 24/7 even when idle.

```bash
bash scripts/aks-down.sh
```

### A6. `demo-app-signed` CrashLoopBackOff on AKS — `exec format error`

**Symptom:**
```
kubectl get pod -n workload
# demo-app-signed-xxx   0/1   CrashLoopBackOff
kubectl logs -n workload demo-app-signed-xxx --previous
# exec ./demo-app: exec format error
```

**Cause:**
You built the image on an Apple Silicon (arm64) Mac without specifying a target
platform, so `docker build` produced an arm64 image. AKS node pools are amd64
by default.

**Fix:**
The fix is already in `demos/demo-app/build-and-push.sh` and `demos/demo4-cicd/run.sh` —
on AKS they default to `TARGET_PLATFORM=linux/amd64` and pass `--platform` to
docker/podman. If you have arm64 AKS nodes instead, override:

```bash
TARGET_PLATFORM=linux/arm64 bash demos/demo-app/build-and-push.sh
```

After rebuilding, force the kubelet to drop the cached image (see A7).

### A7. AKS kubelet keeps using the old cached image — "Container image already present on machine"

**Symptom:**
You rebuilt and re-pushed `demo/app:latest`, but the pod still uses the previous
image. `kubectl describe pod` shows:
```
Successfully assigned ... Container image "<acr>/demo/app:latest" already present on machine
```
…and no `Pulling image` event.

**Cause:**
Kubelet's default `imagePullPolicy` is `IfNotPresent`. With the `:latest` tag,
re-pushing **does not** invalidate the cache — the node keeps the old image.
This bites hardest right after fixing an arch mismatch (A6) because the cached
arm64 image keeps crashing even though the registry now holds the correct amd64
build.

**Fix:**
The demo4 and demo5 deployment specs now hardcode `imagePullPolicy: Always`. If
you still see a stale cached image (e.g. for the chart's signing-job workloads):

```bash
kubectl rollout restart deploy/demo-app-signed -n workload
# Or, more aggressively:
kubectl delete pod -n workload -l app=demo-app-signed
```

For your own manifests, always set `imagePullPolicy: Always` when using mutable
tags like `:latest`. Use immutable digest references (`@sha256:…`) in production.
