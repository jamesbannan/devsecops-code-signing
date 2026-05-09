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
```

Or `scripts/verify.sh` Check 13 fails with `OIDC issuer is 'https://10.x.x.x/...'`.

**Cause:**
minikube was started without the `--extra-config=apiserver.service-account-issuer` flag, so the Kubernetes API server uses an auto-generated issuer URL that Fulcio cannot validate.

**Fix:**
```bash
# Stop and restart minikube with the correct flags
minikube stop
bash scripts/start-minikube.sh

# Verify:
kubectl get --raw /.well-known/openid-configuration | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
# Expected: https://kubernetes.default.svc
```

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
