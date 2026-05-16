output "resource_group_name" {
  description = "Name of the resource group containing all AKS demo resources."
  value       = azurerm_resource_group.this.name
}

output "cluster_name" {
  description = "Name of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.name
}

output "acr_name" {
  description = "Name of the Azure Container Registry."
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  description = "Login server for the Azure Container Registry (e.g. acrdsoacsabc12.azurecr.io)."
  value       = azurerm_container_registry.this.login_server
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for the AKS cluster — required by Fulcio for Kubernetes service-account-token keyless signing."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "location" {
  description = "Azure region the resources were deployed to."
  value       = var.location
}
