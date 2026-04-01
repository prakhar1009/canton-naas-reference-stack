# terraform/modules/aws/main.tf

# ------------------------------------------------------------------------------
# Variables
# ------------------------------------------------------------------------------

variable "aws_region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "The name of the EKS cluster."
  type        = string
  default     = "canton-naas-cluster"
}

variable "cluster_version" {
  description = "The Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.29"
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "A list of Availability Zones to deploy into."
  type        = list(string)
  default     = []
}

variable "private_subnets" {
  description = "A list of CIDR blocks for private subnets."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnets" {
  description = "A list of CIDR blocks for public subnets."
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "tags" {
  description = "A map of tags to assign to all resources."
  type        = map(string)
  default = {
    Project     = "canton-naas-reference-stack"
    ManagedBy   = "Terraform"
    Environment = "production"
  }
}

# ------------------------------------------------------------------------------
# Locals and Data Sources
# ------------------------------------------------------------------------------

locals {
  cluster_name = var.cluster_name
  tags         = var.tags
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Use specified AZs or default to the first 3 available ones
locals {
  azs = length(var.azs) > 0 ? var.azs : slice(data.aws_availability_zones.available.names, 0, 3)
}

# ------------------------------------------------------------------------------
# Networking (VPC, Subnets, etc.)
# ------------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.3"

  name = "${local.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = false # Use one NAT gateway per AZ for HA
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }

  tags = local.tags
}

# ------------------------------------------------------------------------------
# EKS Cluster
# ------------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # KMS Key for encrypting Kubernetes secrets in etcd
  cluster_encryption_config = [{
    provider_key_arn = module.kms.key_arn
    resources        = ["secrets"]
  }]

  # EKS Managed Node Groups
  eks_managed_node_groups = {
    # Core on-demand nodes for critical Canton components (sequencer, mediator)
    core_services = {
      name           = "core-services-ondemand"
      instance_types = ["m5.large", "m5a.large", "m6i.large"]
      min_size       = 2
      max_size       = 5
      desired_size   = 2
      subnet_ids     = module.vpc.private_subnets
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }
    }

    # Scalable spot nodes for tenant validator nodes (cost-effective)
    tenant_validators = {
      name           = "tenant-validators-spot"
      capacity_type  = "SPOT"
      instance_types = ["t3.large", "t3a.large", "m5.large"]
      min_size       = 1
      max_size       = 20
      desired_size   = 2
      subnet_ids     = module.vpc.private_subnets
      labels = {
        "node.canton-naas.io/pool" = "tenant-validators"
      }
      taints = [{
        key    = "canton-naas.io/tenant-node"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  tags = local.tags
}

# ------------------------------------------------------------------------------
# KMS Key for EKS Secret Encryption
# ------------------------------------------------------------------------------

module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "1.6.0"

  alias               = "alias/eks/${local.cluster_name}"
  description         = "KMS key for EKS cluster secrets encryption"
  enable_key_rotation = true
  tags                = local.tags
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "cluster_name" {
  description = "The name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "The endpoint for the EKS cluster's Kubernetes API."
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "The base64 encoded certificate data required to communicate with the cluster."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_oidc_issuer_url" {
  description = "The OIDC issuer URL for the EKS cluster."
  value       = module.eks.cluster_oidc_issuer_url
}

output "vpc_id" {
  description = "The ID of the VPC."
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "List of IDs of private subnets."
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of IDs of public subnets."
  value       = module.vpc.public_subnets
}