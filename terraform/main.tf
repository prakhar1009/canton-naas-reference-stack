################################################################################
# Terraform Configuration
#
# Specifies the required Terraform version, backend for state management,
# and the required cloud providers for the Canton NaaS stack.
################################################################################

terraform {
  required_version = ">= 1.5.0"

  # Example backend configuration using AWS S3.
  # This should be uncommented and configured for your environment.
  # Similar backends exist for GCP (gcs) and Azure (azurerm).
  /*
  backend "s3" {
    bucket         = "your-canton-naas-tfstate-bucket"
    key            = "global/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "your-canton-naas-tfstate-lock"
  }
  */

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
  }
}

################################################################################
# Provider Configurations
#
# Configures the cloud providers. Credentials are expected to be configured
# via environment variables or other standard authentication mechanisms.
# (e.g., AWS_PROFILE, GOOGLE_APPLICATION_CREDENTIALS, ARM_CLIENT_ID, etc.)
################################################################################

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}

provider "azurerm" {
  features {}
}

################################################################################
# Local Values
#
# Defines local variables for consistent naming and tagging across resources.
################################################################################

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Stack       = "CantonNaaSReference"
  }
}

################################################################################
# Cloud-Specific Module Instantiation
#
# Conditionally deploys the Canton NaaS stack to the selected cloud provider
# by invoking the appropriate module.
################################################################################

module "aws_naas_stack" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  source = "./modules/aws"

  # General Configuration
  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  tags        = local.common_tags

  # VPC Configuration
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  # EKS Cluster Configuration
  eks_cluster_version = var.k8s_version
  eks_node_group_config = {
    instance_types = var.k8s_node_instance_types
    min_size       = var.k8s_node_group_min_size
    max_size       = var.k8s_node_group_max_size
    desired_size   = var.k8s_node_group_desired_size
  }

  # RDS Database Configuration
  db_instance_class     = var.db_instance_class
  db_allocated_storage  = var.db_allocated_storage
  db_multi_az           = var.db_multi_az
  db_engine_version     = var.db_engine_version
}

module "gcp_naas_stack" {
  count  = var.cloud_provider == "gcp" ? 1 : 0
  source = "./modules/gcp"

  # General Configuration
  name_prefix    = local.name_prefix
  gcp_project_id = var.gcp_project_id
  gcp_region     = var.gcp_region
  labels         = local.common_tags

  # VPC Configuration
  vpc_cidr = var.vpc_cidr

  # GKE Cluster Configuration
  gke_cluster_version = var.k8s_version
  gke_node_pool_config = {
    machine_type = var.k8s_node_instance_types[0] # GKE often uses a single machine type per pool
    min_count    = var.k8s_node_group_min_size
    max_count    = var.k8s_node_group_max_size
  }

  # Cloud SQL Database Configuration
  db_tier               = var.db_instance_class
  db_disk_size          = var.db_allocated_storage
  db_availability_type  = var.db_multi_az ? "REGIONAL" : "ZONAL"
  db_engine_version     = var.db_engine_version
}

module "azure_naas_stack" {
  count  = var.cloud_provider == "azure" ? 1 : 0
  source = "./modules/azure"

  # General Configuration
  name_prefix         = local.name_prefix
  azure_location      = var.azure_location
  resource_group_name = "rg-${local.name_prefix}"
  tags                = local.common_tags

  # VNet Configuration
  vnet_address_space = [var.vpc_cidr]

  # AKS Cluster Configuration
  aks_cluster_version = var.k8s_version
  aks_node_pool_config = {
    vm_size      = var.k8s_node_instance_types[0] # AKS often uses a single VM size per pool
    min_count    = var.k8s_node_group_min_size
    max_count    = var.k8s_node_group_max_size
    node_count   = var.k8s_node_group_desired_size
  }

  # Azure Database for PostgreSQL Configuration
  db_sku_name           = var.db_instance_class
  db_storage_mb         = var.db_allocated_storage * 1024
  db_high_availability  = var.db_multi_az
  db_engine_version     = var.db_engine_version
}

################################################################################
# Outputs
#
# Exports key information about the deployed infrastructure. The values are
# sourced from the conditionally created cloud-specific module.
################################################################################

output "cloud_provider" {
  description = "The cloud provider where the stack is deployed."
  value       = var.cloud_provider
}

output "kubernetes_cluster_name" {
  description = "The name of the Kubernetes cluster."
  value = var.cloud_provider == "aws" ? module.aws_naas_stack[0].eks_cluster_name : (
    var.cloud_provider == "gcp" ? module.gcp_naas_stack[0].gke_cluster_name : module.azure_naas_stack[0].aks_cluster_name
  )
}

output "kubernetes_cluster_endpoint" {
  description = "The endpoint for the Kubernetes cluster's API server."
  value = var.cloud_provider == "aws" ? module.aws_naas_stack[0].eks_cluster_endpoint : (
    var.cloud_provider == "gcp" ? module.gcp_naas_stack[0].gke_cluster_endpoint : module.azure_naas_stack[0].aks_cluster_endpoint
  )
  sensitive = true
}

output "database_endpoint" {
  description = "The connection endpoint for the PostgreSQL database."
  value = var.cloud_provider == "aws" ? module.aws_naas_stack[0].db_instance_endpoint : (
    var.cloud_provider == "gcp" ? module.gcp_naas_stack[0].db_instance_endpoint : module.azure_naas_stack[0].db_server_fqdn
  )
  sensitive = true
}

output "database_username" {
  description = "The master username for the PostgreSQL database."
  value = var.cloud_provider == "aws" ? module.aws_naas_stack[0].db_instance_username : (
    var.cloud_provider == "gcp" ? module.gcp_naas_stack[0].db_instance_username : module.azure_naas_stack[0].db_admin_username
  )
  sensitive = true
}

output "kms_key_arn" {
  description = "The ARN or ID of the master encryption key used for segregating tenant data."
  value = var.cloud_provider == "aws" ? module.aws_naas_stack[0].kms_key_arn : (
    var.cloud_provider == "gcp" ? module.gcp_naas_stack[0].kms_key_ring_id : module.azure_naas_stack[0].key_vault_id
  )
}