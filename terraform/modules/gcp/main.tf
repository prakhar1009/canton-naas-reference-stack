# terraform/modules/gcp/main.tf

# --------------------------------------------------------------------------------------------------
# CANTON NAAS REFERENCE STACK - GCP GKE MODULE
#
# This module provisions a Google Kubernetes Engine (GKE) cluster optimized
# for running Canton Network validator nodes and associated services. It includes
# networking, a dedicated node pool with autoscaling, and proper service accounts.
# --------------------------------------------------------------------------------------------------

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.50.0"
    }
  }
}

# --------------------------------------------------------------------------------------------------
# Input Variables
# --------------------------------------------------------------------------------------------------

variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
}

variable "region" {
  description = "The GCP region for the GKE cluster and networking."
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "The name for the GKE cluster."
  type        = string
  default     = "canton-naas-validator-cluster"
}

variable "kubernetes_version" {
  description = "The Kubernetes version for the GKE cluster."
  type        = string
  default     = "1.28" # Check for latest stable version
}

variable "network_name" {
  description = "The name of the VPC network."
  type        = string
  default     = "canton-naas-vpc"
}

variable "subnet_name" {
  description = "The name of the subnet for the GKE cluster."
  type        = string
  default     = "canton-naas-gke-subnet"
}

variable "ip_cidr_range" {
  description = "The IP address range for the GKE subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "machine_type" {
  description = "The machine type for the GKE nodes."
  type        = string
  default     = "e2-standard-4" # Good balance of CPU/memory for Canton nodes
}

variable "disk_size_gb" {
  description = "The disk size in GB for each GKE node."
  type        = number
  default     = 100
}

variable "min_node_count" {
  description = "Minimum number of nodes in the autoscaling node pool."
  type        = number
  default     = 1
}

variable "max_node_count" {
  description = "Maximum number of nodes in the autoscaling node pool."
  type        = number
  default     = 5
}

variable "initial_node_count" {
  description = "Initial number of nodes in the node pool."
  type        = number
  default     = 2
}

variable "labels" {
  description = "A map of labels to apply to all resources."
  type        = map(string)
  default = {
    "managed-by"  = "terraform"
    "project"     = "canton-naas-reference-stack"
    "environment" = "production"
  }
}

# --------------------------------------------------------------------------------------------------
# Networking
# --------------------------------------------------------------------------------------------------

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "subnet" {
  project                  = var.project_id
  name                     = var.subnet_name
  ip_cidr_range            = var.ip_cidr_range
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# --------------------------------------------------------------------------------------------------
# Service Account for GKE Nodes
# --------------------------------------------------------------------------------------------------

resource "google_service_account" "gke_nodes_sa" {
  project      = var.project_id
  account_id   = "${var.cluster_name}-nodes-sa"
  display_name = "Service Account for GKE Nodes in ${var.cluster_name}"
}

# Grant necessary roles for node operation and monitoring
resource "google_project_iam_member" "gke_nodes_sa_roles" {
  for_each = toset([
    "roles/monitoring.viewer",
    "roles/logging.logWriter",
    "roles/storage.objectViewer", # For pulling images from GCR/Artifact Registry
    "roles/artifactregistry.reader"
  ])

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.gke_nodes_sa.email}"
}

# --------------------------------------------------------------------------------------------------
# GKE Cluster
# --------------------------------------------------------------------------------------------------

resource "google_container_cluster" "primary" {
  project                = var.project_id
  name                   = var.cluster_name
  location               = var.region
  remove_default_node_pool = true
  initial_node_count     = 1 # Required even when removing default pool

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  min_master_version = var.kubernetes_version

  # Enable monitoring and logging with Google Cloud Operations Suite
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
    managed_prometheus {
      enabled = true
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  # Enable Workload Identity for secure access to GCP services from pods
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Hardening and security best practices
  ip_allocation_policy {} # Use VPC-native traffic routing
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # Keep public endpoint for kubectl access
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    # It's highly recommended to restrict access to known IP ranges
    # Leaving it open for this reference implementation for simplicity.
    # Example:
    # cidr_blocks {
    #   cidr_block   = "YOUR_OFFICE_IP/32"
    #   display_name = "Office"
    # }
  }

  labels = var.labels
}

# --------------------------------------------------------------------------------------------------
# GKE Node Pool for Canton Validator Nodes
# --------------------------------------------------------------------------------------------------

resource "google_container_node_pool" "validator_nodes" {
  project    = var.project_id
  name       = "validator-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = var.initial_node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb
    disk_type    = "pd-standard"

    # Use the dedicated service account
    service_account = google_service_account.gke_nodes_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = merge(var.labels, {
      "node-pool" = "validator-nodes"
    })

    tags = ["gke-node", "${var.cluster_name}-node"]

    # Preemptible VMs can reduce costs but are not recommended for stateful
    # production Canton nodes unless your high-availability strategy accounts for it.
    # preemptible  = false
  }

  # Ensure the cluster is created before the node pool
  depends_on = [google_container_cluster.primary]
}


# --------------------------------------------------------------------------------------------------
# Outputs
# --------------------------------------------------------------------------------------------------

output "cluster_name" {
  description = "The name of the GKE cluster."
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "The public endpoint of the GKE cluster."
  value       = google_container_cluster.primary.endpoint
}

output "cluster_ca_certificate" {
  description = "The base64 encoded CA certificate for the GKE cluster."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "node_pool_name" {
  description = "The name of the validator node pool."
  value       = google_container_node_pool.validator_nodes.name
}

output "gke_nodes_service_account_email" {
  description = "The email of the service account used by the GKE nodes."
  value       = google_service_account.gke_nodes_sa.email
}

output "network_name" {
  description = "The name of the VPC created for the cluster."
  value       = google_compute_network.vpc.name
}