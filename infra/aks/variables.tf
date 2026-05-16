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

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    project = "devsecops-code-signing"
    env     = "dev"
    purpose = "bsides-melbourne-demo"
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
