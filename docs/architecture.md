# Architecture

## Overview

The DevSecOps demo environment deploys a complete code-signing stack on a single
Kubernetes cluster via `helm install`. The same chart targets either a **local minikube**
cluster (NodePort access, in-cluster Docker Registry) or **Azure Kubernetes Service**
(ClusterIP + port-forward access, Azure Container Registry as the image store). All
in-cluster components — step-ca, Fulcio, Rekor, TUF, Trillian, Kyverno — are identical
across both targets; only the registry and OIDC issuer differ.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                  Kubernetes Cluster (minikube or AKS)                        ║
║                                                                              ║
║  ┌──────────────────┐   ┌────────────────────────────────────────────────┐  ║
║  │   pki namespace  │   │          Sigstore (scaffold chart)              │  ║
║  │                  │   │                                                  │  ║
║  │  ┌────────────┐  │   │  ┌──────────────┐   ┌─────────────────────┐   │  ║
║  │  │  step-ca   │  │   │  │    Fulcio     │   │       Rekor         │   │  ║
║  │  │  :9000     │  │   │  │  :80 / :5554 │   │       :3000         │   │  ║
║  │  │  JWK prov  │  │   │  │  (CA)        │   │  (transparency log) │   │  ║
║  │  │  K8sSA     │  │   │  └──────────────┘   └──────┬──────────────┘   │  ║
║  │  └──────┬─────┘  │   │         │                   │                  │  ║
║  │         │        │   │  ┌──────────────┐   ┌───────┴─────────────┐   │  ║
║  │  step-ca-root    │   │  │    ctlog      │   │     Trillian        │   │  ║
║  │  ConfigMap       │   │  │  (CT log)    │   │  log-server/signer  │   │  ║
║  └──────┬───────────┘   │  └──────────────┘   │  MySQL              │   │  ║
║         │               │                     └─────────────────────┘   │  ║
║         │               │  ┌──────────────┐   ┌─────────────────────┐   │  ║
║         │               │  │     TUF      │   │     Rekor Redis     │   │  ║
║         │               │  │   :80        │   │     (cache)         │   │  ║
║         │               │  │  (trust root)│   └─────────────────────┘   │  ║
║         │               │  └──────────────┘                              │  ║
║         │               └────────────────────────────────────────────────┘  ║
║         │                                                                    ║
║  ┌──────┴───────────────────────────────────────────────────────────────┐   ║
║  │                        workload namespace                             │   ║
║  │                                                                       │   ║
║  │  ┌──────────────────────┐   ┌─────────────────────────────────────┐  │   ║
║  │  │  signing-job-        │   │  signing-job-sigstore               │  │   ║
║  │  │  smallstep           │   │  - projected SA token (sigstore)    │  │   ║
║  │  │  - step-cli init     │   │  - cosign initialize (TUF)          │  │   ║
║  │  │  - cosign sign       │   │  - cosign sign --fulcio-url         │  │   ║
║  │  │    --key cert.pem    │   │    --rekor-url --identity-token     │  │   ║
║  │  └──────────────────────┘   └─────────────────────────────────────┘  │   ║
║  │                                                                       │   ║
║  │  ┌──────────────────────┐   ┌─────────────────────────────────────┐  │   ║
║  │  │  verification-job    │   │  demo-app (Deployment)              │  │   ║
║  │  │  - cosign verify     │   │  - GET / → build metadata JSON      │  │   ║
║  │  │    (both paths)      │   │  - IMAGE_SIGNED env var             │  │   ║
║  │  │  - JSON output       │   │  - :8080                            │  │   ║
║  │  └──────────────────────┘   └─────────────────────────────────────┘  │   ║
║  └───────────────────────────────────────────────────────────────────────┘  ║
║                                                                              ║
║  ┌───────────────────────┐   ┌───────────────────────────────────────────┐  ║
║  │  registry namespace   │   │          policy namespace                 │  ║
║  │                       │   │                                           │  ║
║  │  ┌─────────────────┐  │   │  ┌────────────────────────────────────┐  │  ║
║  │  │  Docker Reg v2  │  │   │  │  Kyverno admission controller      │  │  ║
║  │  │  :5000 / 30500  │  │   │  │  + background/cleanup/reports      │  │  ║
║  │  │  (no auth)      │  │   │  │  ClusterPolicy: require-sig        │  │  ║
║  │  │  delete enabled │  │   │  │  ClusterPolicy: audit-admission    │  │  ║
║  │  └─────────────────┘  │   │  └────────────────────────────────────┘  │  ║
║  └───────────────────────┘   └───────────────────────────────────────────┘  ║
╚══════════════════════════════════════════════════════════════════════════════╝
         │                              │
         │ NodePort :30500 (local)       │ Admission webhook (in-cluster)
         │ port-forward to host          │
         ▼                              ▼
   Host machine                   Every Pod creation
   (cosign, podman,                in workload namespace
    step CLI)                      triggers policy check
```

---

## Component Descriptions

### Smallstep CA (step-ca)
**Namespace:** `pki`

A private certificate authority based on [Smallstep step-ca](https://smallstep.com/docs/step-ca/).
Issues short-lived X.509 certificates (5-minute default, 10-minute maximum) via two provisioners:

- **workload-signer (JWK):** Interactive provisioner for Demo 2. Requires a password to request a token, which is then used to obtain a certificate.
- **k8s-signing (K8sSA):** Automated provisioner that accepts Kubernetes ServiceAccount JWTs directly. Used by the in-cluster signing jobs.

The root CA certificate is propagated to the `workload` namespace via a post-install Job (`ca-root-propagator`) so signing jobs can trust it without host-side configuration.

### Docker Registry v2
**Namespace:** `registry`

A vanilla [Docker Registry v2](https://distribution.github.io/distribution/) instance used to store the demo container images and their cosign signatures/attestations. Configured without authentication (intentional for local demo — not suitable for production). Delete is enabled so images can be replaced between demo runs.

In local mode, exposed as a NodePort on `:30500` for host-side access. In cloud mode, exposed as ClusterIP.

### Sigstore (scaffold chart)
**Namespaces:** `fulcio-system`, `rekor-system`, `ctlog-system`, `tuf-system`, `trillian-system`

The [Sigstore scaffold Helm chart](https://github.com/sigstore/helm-charts) deploys the complete Sigstore stack:

- **Fulcio:** A certificate authority that issues short-lived code-signing certificates based on OIDC identity. Configured with `ephemeralca` mode and the Kubernetes OIDC issuer.
- **Rekor:** An immutable, append-only transparency log for signing events. Every `cosign sign` call records an entry.
- **ctlog:** A Certificate Transparency log for Fulcio-issued certificates.
- **Trillian:** The underlying Merkle tree database backing both Rekor and ctlog.
- **TUF:** A [The Update Framework](https://theupdateframework.io/) mirror distributing the trust roots (Fulcio root cert, Rekor public key, ctlog public key) so cosign can verify them without trusting a single server.

### Kyverno
**Namespace:** `policy`

[Kyverno](https://kyverno.io/) is a Kubernetes-native policy engine that integrates with the admission webhook to enforce policies at runtime. Two ClusterPolicies are deployed:

- **require-image-signature:** Validates cosign signatures on all Pods in the `workload` namespace. Supports both Smallstep CA (certificate chain) and Sigstore keyless (Rekor + OIDC issuer) verification modes. Default: `Audit`; switch to `Enforce` for Demo 5.
- **audit-signed-image-admission:** Generates PolicyReport entries for every Pod admission. Provides the CISO-friendly audit trail shown in Demo 6.

### Demo Application
**Namespace:** `workload`

A minimal Go HTTP server (`main.go`) that returns its build metadata as JSON:

```json
{"version":"1.0.0","sha":"abc1234","built":"2026-04-03T10:00:00Z","signed":false}
```

The `signed` field reflects the `IMAGE_SIGNED=true` environment variable, so signed and unsigned deployments are visually distinguishable.

---

## Data Flow: Smallstep Signing Path

```
  Pod (signing-job-smallstep)
       │
       ├─ initContainer (step-cli)
       │   ├─ Reads step-ca-root ConfigMap (propagated from pki namespace)
       │   ├─ Uses K8s SA token (projected, audience=step-ca FQDN)
       │   ├─ POST /1.0/sign → step-ca.pki.svc:9000
       │   │   └─ step-ca validates SA token via Kubernetes TokenReview API
       │   │   └─ step-ca issues X.509 cert (CN=signing-key, notAfter=+5m)
       │   └─ Writes cert.pem + key.pem to emptyDir volume
       │
       └─ container (cosign)
           ├─ cosign sign --key key.pem --certificate cert.pem --certificate-chain root_ca.crt
           │   └─ Signs image digest with ephemeral key
           │   └─ Embeds cert + chain in the signature
           └─ cosign pushes signature to registry as an OCI 1.1 referrer
              └─ signature manifest with subject: registry/demo/app@sha256:<digest>
```

**Verification:** `cosign verify --certificate-chain root_ca.crt` validates the cert was issued by the step-ca root CA and the signature matches the image digest.

---

## Data Flow: Sigstore Keyless Signing Path

```
  Pod (signing-job-sigstore)
       │
       ├─ Volume: projected SA token (audience=sigstore, expiry=10m)
       │
       └─ container (cosign)
           ├─ cosign initialize --mirror TUF_MIRROR/root.json
           │   └─ Fetches Fulcio root cert, Rekor pubkey from local TUF mirror
           │
           ├─ cosign sign --fulcio-url FULCIO_URL --rekor-url REKOR_URL --identity-token <token>
           │   │
           │   ├─ cosign generates ephemeral key pair (in memory)
           │   │
           │   ├─ POST /api/v1/signingCert → Fulcio (fulcio-server.fulcio-system.svc)
           │   │   ├─ Fulcio verifies SA JWT against the cluster's OIDC issuer JWKS
           │   │   │     • minikube: https://kubernetes.default.svc
           │   │   │     • AKS:      https://<region>.oic.prod-aks.azure.com/<tenant>/<cluster>/
           │   │   │   (Fulcio's OIDCIssuers config lists both — same chart works on either target)
           │   │   ├─ Fulcio issues cert: Subject=SA identity, notAfter=+10m
           │   │   └─ Returns signed certificate
           │   │
           │   ├─ cosign signs image digest with ephemeral private key
           │   │
           │   ├─ POST /api/v1/log/entries → Rekor (rekor-server.rekor-system.svc)
           │   │   └─ Rekor appends {digest, cert, sig} to the Merkle tree
           │   │   └─ Returns: logIndex, UUID, signedEntryTimestamp
           │   │
           │   └─ cosign pushes signature + Rekor bundle as an OCI 1.1 referrer
           │      └─ signature manifest with subject: registry/demo/app@sha256:<digest>
           │
           └─ cosign discards ephemeral private key (never persisted)
```

**Verification:** `cosign verify --rekor-url ... --certificate-identity ... --certificate-oidc-issuer ...` validates the Rekor log entry, cert chain via TUF roots, and the identity claims in the certificate.

---

## Why Two Paths?

| Dimension | Smallstep CA (private PKI) | Sigstore keyless |
|-----------|---------------------------|-----------------|
| **Trust model** | Internal CA hierarchy — your org controls the root | Public Fulcio CA — trust via TUF, backed by Sigstore foundation |
| **Audit trail** | Private (only in your infrastructure) | Public Rekor log — verifiable by anyone, forever |
| **Air-gapped** | Works offline | Requires Fulcio + Rekor (can be self-hosted) |
| **Identity** | Whatever your step-ca provisioner accepts | OIDC issuer (GitHub Actions, Kubernetes, Google, etc.) |
| **Key management** | step-ca handles rotation | No keys to manage |
| **Compliance** | Easier for orgs with existing PKI | Stronger non-repudiation (public log) |

The two paths are **complementary, not competing**. Many enterprises run private PKI for internal workloads and use Sigstore keyless for publicly verifiable CI/CD signing.

---

## Port Reference

| Service | Namespace | In-cluster DNS | Host port (minikube NodePort) | AKS access |
|---------|-----------|----------------|-------------------------------|------------|
| Docker Registry | registry | `registry.registry.svc:5000` | `localhost:30500` | Not deployed — ACR replaces it on AKS |
| Rekor | rekor-system | `rekor-server.rekor-system.svc:3000` | `localhost:30300` | `kubectl port-forward` (via `scripts/port-forward.sh`) |
| Fulcio | fulcio-system | `fulcio-server.fulcio-system.svc:80` | `localhost:30200` | `kubectl port-forward` |
| TUF mirror | tuf-system | `tuf.tuf-system.svc:80` | `localhost:30100` | `kubectl port-forward` |
| step-ca | pki | `step-ca.pki.svc:9000` | `localhost:39000` | `kubectl port-forward` |
| Azure Container Registry | _(external)_ | n/a | n/a | `<acr>.azurecr.io` (managed by `aks-up.sh`, AcrPull on AKS UAMI) |

---

## Cluster Topology Differences

| Concern | minikube | AKS |
|---------|----------|-----|
| Image registry | In-cluster Docker Registry v2 (NodePort 30500) | Azure Container Registry (Premium SKU, attached via AcrPull role on the kubelet UAMI) |
| Host registry push | `minikube image build` + `ctr push` (Docker Desktop's VM cannot reach NodePort) | `az acr login` + `docker push` / `podman push` |
| OIDC issuer | `https://kubernetes.default.svc` (set via `--extra-config=apiserver.service-account-issuer` in `start-minikube.sh`) | AKS-managed: `https://<region>.oic.prod-aks.azure.com/<tenant>/<cluster>/` (read from `terraform output oidc_issuer_url`) |
| Service exposure | NodePort on `$(minikube ip)` | ClusterIP only; host access via `kubectl port-forward` |
| Storage class | `standard` (hostPath) | `managed-csi` (Azure Disk CSI) |
| Provisioning | `scripts/start-minikube.sh` | `scripts/aks-up.sh` → Terraform (`infra/aks/`) creates RG + ACR + UAMI + AKS, then renders `chart/values-aks.local.yaml` |

The Helm chart picks the right values file via `_cluster-detect.sh`: when `CLUSTER_KIND=aks`,
`install.sh` automatically appends `-f chart/values-aks.local.yaml`. Demo scripts use
`$REGISTRY` / `$CLUSTER_REGISTRY` (host vs in-cluster pull) and `$AKS_OIDC_ISSUER_URL` for
the keyless verification flags.
