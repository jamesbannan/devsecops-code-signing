resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
  numeric = true
}

locals {
  suffix       = random_string.suffix.result
  rg_name      = "rg-${var.name_prefix}-${local.suffix}"
  cluster_name = "aks-${var.name_prefix}-${local.suffix}"
  acr_name     = "acr${var.name_prefix}${local.suffix}"
  uami_name    = "uami-${var.name_prefix}-${local.suffix}"
  dns_prefix   = "${var.name_prefix}-${local.suffix}"
}

resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = var.location
  tags     = var.tags
}

# Inlined replacement for the Azure/avm-ptn-aks-dev/azurerm pattern module.
# The AVM module v0.2.0 hard-codes Standard_DS2_v2 for the default node pool with no
# override, which is blocked by the subscription quota in some regions. We mirror the
# module's resource set here so we can set the VM SKU via var.node_vm_size.

resource "azurerm_container_registry" "this" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  sku                 = "Premium"
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "aks" {
  name                = local.uami_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                              = local.cluster_name
  location                          = var.location
  resource_group_name               = azurerm_resource_group.this.name
  dns_prefix                        = local.dns_prefix
  kubernetes_version                = var.kubernetes_version
  automatic_upgrade_channel         = "patch"
  node_os_upgrade_channel           = "NodeImage"
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  role_based_access_control_enabled = true
  sku_tier                          = var.sku_tier
  support_plan                      = var.support_plan
  tags                              = var.tags

  default_node_pool {
    name                    = "agentpool"
    vm_size                 = var.node_vm_size
    auto_scaling_enabled    = true
    host_encryption_enabled = false
    min_count               = var.node_count_min
    max_count               = var.node_count_max
    max_pods                = 110
    os_sku                  = "Ubuntu"

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
    # Must be null on AKSLongTermSupport clusters: LTS rejects the Calico addon
    # with "LTSUnsupportedAddon". The chart renders no NetworkPolicy resources,
    # so enforcement here is unused. Set to "calico" when moving back to a
    # KubernetesOfficial version if you need it.
    network_policy = var.network_policy
  }

  lifecycle {
    ignore_changes = [
      kubernetes_version
    ]
  }
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}
