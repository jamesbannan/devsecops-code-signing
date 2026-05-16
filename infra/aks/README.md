# infra/aks — Dev/Test AKS Terraform Stack

Provisions a dev/test Azure Kubernetes Service (AKS) cluster, Azure Container
Registry (ACR), and a User Assigned Managed Identity in a single resource group.

The configuration originally wrapped the
[`Azure/avm-ptn-aks-dev/azurerm`](https://registry.terraform.io/modules/Azure/avm-ptn-aks-dev/azurerm/latest)
pattern module (v0.2.0). That module is excellent but **hard-codes
`Standard_DS2_v2`** for the default node pool with no override input, which is
not permitted in every subscription/region. The stack now inlines an equivalent
resource set so the VM SKU, node counts, and load-balancer SKU can be tuned.
The shape and identity boundaries match the AVM module so the chart's
assumptions (OIDC issuer enabled, workload identity, AcrPull role assignment)
all hold.

The cluster is intended for the BSides Melbourne 2026 DevSecOps code-signing demo
and is **not** production-hardened. State is held in a local `terraform.tfstate`
file (gitignored).

## Prerequisites

| Tool       | Version  |
|------------|----------|
| terraform  | >= 1.5.0 |
| az (Azure CLI) | >= 2.60 |

Authenticated to Azure:

```bash
az login
az account set --subscription "<your-subscription-id>"
```

## Usage

Prefer the repo-root wrapper:

```bash
bash scripts/aks-up.sh        # terraform apply + kubeconfig + values render
bash scripts/aks-down.sh      # full teardown: helm uninstall + terraform destroy
bash scripts/cleanup.sh       # reset demo without destroying AKS (saves cluster spin-up time)
```

Use `cleanup.sh` when you only want to wipe the demo workload (helm release,
demo namespaces, orphan Kyverno webhooks, stuck PVCs) and re-run `install.sh`
on the same AKS cluster. Use `aks-down.sh` when you're truly done.

Direct Terraform usage:

```bash
cd infra/aks
terraform init
terraform apply
terraform destroy
```

## Inputs

| Variable             | Default              | Description                                         |
|----------------------|----------------------|-----------------------------------------------------|
| `location`           | `australiaeast`      | Azure region                                        |
| `name_prefix`        | `dsoacs`             | 3-8 chars, lowercase alphanumeric                   |
| `kubernetes_version` | `1.33`               | AKS minor version (must be supported in `location`) |
| `node_vm_size`       | `Standard_D2s_v5`    | Default node-pool VM SKU                            |
| `node_count_min`     | `2`                  | Autoscaler minimum                                  |
| `node_count_max`     | `3`                  | Autoscaler maximum                                  |
| `tags`               | demo defaults        | Applied to all resources                            |
| `enable_telemetry`   | `false`              | Reserved (unused since module was inlined)          |

Pick a `node_vm_size` permitted in your subscription/region. List allowed SKUs:

```bash
az vm list-skus --location "$LOCATION" --resource-type virtualMachines \
  --query "[?restrictions==null].name" -o tsv | sort -u
```

## Outputs

| Output                 | Purpose                                     |
|------------------------|---------------------------------------------|
| `resource_group_name`  | RG containing all resources                 |
| `cluster_name`         | AKS cluster name                            |
| `acr_name`             | ACR name                                    |
| `acr_login_server`     | ACR login server hostname                   |
| `oidc_issuer_url`      | AKS OIDC issuer URL (Fulcio configuration)  |
| `location`             | Azure region                                |

## Cost note

Dev/test sizing (two Standard_D2s_v5 nodes + ACR Premium + load balancer)
runs at low single-digit AUD/hour. Destroy the stack between demo sessions.
