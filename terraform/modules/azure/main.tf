# ---------------------------------------------------------------------------------------------------------------------
# AZURE KUBERNETES SERVICE (AKS) MODULE FOR CANTON NETWORK
#
# This module provisions the necessary Azure infrastructure to run a Canton Network validator or participant node,
# including:
#   - An Azure Kubernetes Service (AKS) cluster with auto-scaling.
#   - A dedicated Virtual Network (VNet) and Subnet for network isolation.
#   - An Azure Key Vault for Hardware Security Module (HSM)-backed cryptographic key management (Canton KMS).
#   - Azure Log Analytics for monitoring and logging.
#   - Appropriate Identity and Access Management (IAM) roles for secure operation.
# ---------------------------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------------------------
# Module Input Variables
# ---------------------------------------------------------------------------------------------------------------------

variable "cluster_name" {
  description = "The name for the AKS cluster and associated resources."
  type        = string
}

variable "location" {
  description = "The Azure region where all resources will be created."
  type        = string
}

variable "resource_group_name" {
  description = "The name of the Azure Resource Group to host the infrastructure."
  type        = string
}

variable "kubernetes_version" {
  description = "The version of Kubernetes to use for the AKS cluster."
  type        = string
  default     = "1.28.5"
}

variable "node_count" {
  description = "The initial number of nodes in the default node pool."
  type        = number
  default     = 2
}

variable "min_node_count" {
  description = "The minimum number of nodes for the cluster autoscaler."
  type        = number
  default     = 1
}

variable "max_node_count" {
  description = "The maximum number of nodes for the cluster autoscaler."
  type        = number
  default     = 5
}

variable "vm_size" {
  description = "The Azure VM size for the Kubernetes nodes. Recommended: Standard_D4s_v3 or higher."
  type        = string
  default     = "Standard_D4s_v3"
}

variable "tenant_id" {
  description = "The Azure Tenant ID where the resources are being deployed."
  type        = string
}

variable "tags" {
  description = "A map of tags to apply to all provisioned resources."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------------------------------------------------
# Core Resources
# ---------------------------------------------------------------------------------------------------------------------

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------------------------------------------------
# Networking Infrastructure
# ---------------------------------------------------------------------------------------------------------------------

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.cluster_name}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "aks_subnet" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ---------------------------------------------------------------------------------------------------------------------
# Azure Key Vault for Canton KMS Integration
# ---------------------------------------------------------------------------------------------------------------------

resource "azurerm_key_vault" "kv" {
  name                        = "${var.cluster_name}-kv-${random_string.suffix.result}"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  tenant_id                   = var.tenant_id
  sku_name                    = "premium" # "premium" SKU is required for HSM-backed keys
  soft_delete_retention_days  = 7
  purge_protection_enabled    = true
  enable_rbac_authorization   = false # Use access policies for simplicity in this module

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  tags = var.tags
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# ---------------------------------------------------------------------------------------------------------------------
# Azure Kubernetes Service (AKS) Cluster
# ---------------------------------------------------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  default_node_pool {
    name                = "default"
    node_count          = var.node_count
    vm_size             = var.vm_size
    vnet_subnet_id      = azurerm_subnet.aks_subnet.id
    os_disk_type        = "Managed"
    os_disk_size_gb     = 128
    enable_auto_scaling = true
    min_count           = var.min_node_count
    max_count           = var.max_node_count
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "calico" # Recommended for enforcing network policies between Canton participants
    service_cidr   = "10.1.0.0/16"
    dns_service_ip = "10.1.0.10"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.la.id
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Logging and Monitoring
# ---------------------------------------------------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "la" {
  name                = "${var.cluster_name}-la"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ---------------------------------------------------------------------------------------------------------------------
# Identity and Access Management for KMS
# ---------------------------------------------------------------------------------------------------------------------

# Grants the AKS cluster's managed identity the necessary permissions on the Key Vault.
# This allows pods (with workload identity) to use the keys for Canton's cryptographic operations.
resource "azurerm_key_vault_access_policy" "aks_kubelet_identity_policy" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = azurerm_kubernetes_cluster.aks.kubelet_identity[0].tenant_id
  object_id    = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id

  # Permissions required for Canton KMS integration with Azure Key Vault
  key_permissions = [
    "Get",
    "List",
    "Create",
    "Sign",
    "Verify",
    "WrapKey",
    "UnwrapKey",
    "Encrypt",
    "Decrypt",
    "Purge",
    "Delete"
  ]

  secret_permissions = [
    "Get",
    "List"
  ]
}


# ---------------------------------------------------------------------------------------------------------------------
# Module Outputs
# ---------------------------------------------------------------------------------------------------------------------

output "resource_group_name" {
  description = "The name of the resource group where infrastructure is deployed."
  value       = azurerm_resource_group.rg.name
}

output "cluster_name" {
  description = "The FQDN of the AKS cluster."
  value       = azurerm_kubernetes_cluster.aks.name
}

output "kube_config" {
  description = "Kubernetes configuration file content for connecting to the cluster."
  value       = azurerm_kubernetes_cluster.aks.kube_config_raw
  sensitive   = true
}

output "key_vault_name" {
  description = "The name of the Azure Key Vault for Canton KMS."
  value       = azurerm_key_vault.kv.name
}

output "key_vault_uri" {
  description = "The URI of the Azure Key Vault."
  value       = azurerm_key_vault.kv.vault_uri
}

output "aks_kubelet_identity_object_id" {
  description = "The Object ID of the AKS Kubelet Managed Identity."
  value       = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}