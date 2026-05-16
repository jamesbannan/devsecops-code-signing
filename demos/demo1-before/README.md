# Demo 1 — The Painful Baseline (Manual GPG Signing)

## Prerequisites

- Stack deployed: `bash scripts/install.sh` (minikube or AKS) completed.
- Port-forwards running (automatic via `install.sh`) or ACR reachable on AKS.
- `demo/app:latest` in the registry is **optional** — Demo 1 falls back to a
  placeholder digest if the manifest isn't present. To make the digest real,
  run `bash demos/demo-app/build-and-push.sh` first.

## What this demo shows

The "before" picture: pre-Sigstore container signing with long-lived GPG keys.
Generates a 2048-bit RSA GPG key in a throw-away `GNUPGHOME`, computes the
manifest digest of `demo/app:latest`, signs that digest with `gpg --detach-sign`,
and verifies it. The narration calls out the six structural problems (no expiry,
on-disk key, no audit trail, manual digest tracking, ad-hoc signature storage,
no identity binding).

Run it with:

```bash
bash demos/demo1-before/run.sh
```

## What changes when the script runs

| Scope | Effect | Persists after script exits? |
|-------|--------|------------------------------|
| Filesystem | Creates `/tmp/demo1-gpg-XXXXXX/{.gnupg,keygen.batch,digest.txt,digest.sig}` | **No** — cleaned up by `trap cleanup EXIT` |
| GPG agent | Spawns a `gpg-agent` rooted at the temp `GNUPGHOME` | **No** — killed on exit |
| Kubernetes / cluster state | None | n/a |
| Container registry | None — only **reads** the manifest of `demo/app:latest` | n/a |
| Rekor / Fulcio / step-ca | None | n/a |

> This is the only demo that doesn't write to the cluster. It's a contrast piece,
> not a deployment. Nothing in `kubectl get all -A` should differ before vs after.

## How to verify (CLI)

The script is self-narrating — it prints `[OK]` markers at each milestone. To
independently confirm correctness while or after it runs:

```bash
# 1. Confirm the registry IS reachable (the script reads it to compute the digest)
#    minikube:
curl -s http://localhost:30500/v2/demo/app/manifests/latest | head -c 80
#    AKS:
az acr repository show-manifests -n "$ACR_NAME" --repository demo/app --top 1 -o table

# 2. Confirm no demo-1 artefacts are left behind
ls /tmp/demo1-gpg-* 2>/dev/null      # expected: no such file
pgrep -fa "gpg-agent.*demo1-gpg"     # expected: no matches

# 3. Confirm the cluster state is unchanged (idempotency check)
kubectl get all -A | wc -l           # same number of lines before/after
```

If you want to inspect the (ephemeral) artefacts while the script is paused at
one of its `sleep` steps, run a second terminal and `ls /tmp/demo1-gpg-*/`.
There you'll see `cert`/`key` materials plus the detached `.sig` — these are
exactly the kind of files that, in 2018-era pipelines, would have been checked
into Git, emailed around, or stashed in S3.

## How to verify (visual UIs)

This demo has no in-cluster footprint, so most cluster UIs will be unchanged.
What you **can** look at:

| UI | minikube | AKS |
|----|----------|-----|
| Container registry browser | <http://localhost:30500/v2/_catalog> (raw JSON in your browser) and <http://localhost:30500/v2/demo/app/manifests/latest> | Azure Portal → your ACR → **Repositories** → `demo/app` → **Tags** → click `latest` → **Manifest** tab |
| Cluster dashboard (to prove nothing changed) | `minikube dashboard` — leave it open during the run | Azure Portal → AKS cluster → **Workloads** (refresh: no new pods) |

In the registry view, copy the manifest digest (`sha256:…` in the response
headers or the "Manifest" tab). That's the **same digest** the script is
asking GPG to sign — but neither GPG nor the registry has any link between
them, which is exactly the point of the demo.

## Talking points to verify visually

When the script finishes you should be able to point at all of the following
and confirm they're true:

- The `.sig` file in `/tmp/demo1-gpg-*` is **gone** (script's cleanup ran).
- The registry has **no** signature referrers attached to `demo/app:latest`
  (contrast with Demo 2/3, where `cosign tree` will show signature
  artefacts as OCI referrers under the image digest).
- The Kyverno `PolicyReport` count in the `workload` namespace is **unchanged**:
  ```bash
  kubectl get policyreport -n workload --no-headers | wc -l
  ```

## minikube vs AKS notes

The script behaves identically on both targets. The only environment-dependent
piece is the registry URL used to fetch the manifest digest — `_cluster-detect.sh`
sets `REGISTRY` to either `localhost:30500` (minikube) or `<acr>.azurecr.io`
(AKS). The digest will of course differ between targets (different push paths
produce different manifests), but that's incidental — Demo 1 doesn't care about
the digest value, only that it exists.

If `curl http://$REGISTRY/v2/...` fails on AKS (you can't hit ACR over plain
HTTP), the script falls back to a placeholder digest and the GPG flow still
runs. The narrative is unaffected.

## Cleanup

Automatic, via `trap cleanup EXIT`. No manual steps required.
