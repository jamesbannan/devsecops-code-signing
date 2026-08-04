variable "location" {
  description = "Azure region where the resource group and AKS cluster are deployed."
  type        = string
  default     = "australiaeast"
}

variable "name_prefix" {
  description = "Short prefix (3-8 chars, lowercase alphanumeric) used to derive resource names. ACR names must be globally unique and alphanumeric only."
  type        = string
  default     = "dsoacs"

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.name_prefix))
    error_message = "name_prefix must be 3-8 lowercase alphanumeric characters."
  }
}

variable "kubernetes_version" {
  description = "AKS Kubernetes minor version (e.g. \"1.33\"). Leave null to let AKS pick the default."
  type        = string
  default     = "1.33"
}

variable "sku_tier" {
  description = <<-EOT
    AKS control-plane SKU tier. Must be "Premium" when kubernetes_version is a
    Long Term Support release (1.33 and older are LTS-only as of Aug 2026).
    "Free" or "Standard" only work on KubernetesOfficial versions (1.34+).
  EOT
  type        = string
  default     = "Premium"
}

variable "support_plan" {
  description = <<-EOT
    "AKSLongTermSupport" (required for LTS versions, needs sku_tier = "Premium")
    or "KubernetesOfficial" (community-supported versions, any tier).
  EOT
  type        = string
  default     = "AKSLongTermSupport"
}

variable "network_policy" {
  description = <<-EOT
    Network policy engine ("calico", "azure") or null to disable. Must be null
    when support_plan is "AKSLongTermSupport" — LTS does not support the Calico
    addon. The demo chart creates no NetworkPolicy resources.
  EOT
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    project = "devsecops-code-signing"
    env     = "dev"
    purpose = "code-signing-demo"
  }
}

variable "node_vm_size" {
  description = "VM size for the AKS default node pool. Choose a SKU permitted in your subscription/region (e.g. Standard_D2s_v5, Standard_D2as_v5)."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "node_count_min" {
  description = "Minimum node count for the default node pool autoscaler."
  type        = number
  default     = 2
}

variable "node_count_max" {
  description = "Maximum node count for the default node pool autoscaler."
  type        = number
  default     = 3
}
