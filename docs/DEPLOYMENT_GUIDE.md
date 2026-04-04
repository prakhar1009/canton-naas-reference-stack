# Canton NaaS Reference Stack: Deployment Guide

This guide provides step-by-step instructions for deploying the Canton Network as a Service (NaaS) Reference Stack on Amazon Web Services (AWS), Google Cloud Platform (GCP), and Microsoft Azure.

This stack uses Terraform to provision the core cloud infrastructure and Helm to deploy the Canton Network components onto a Kubernetes cluster.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Architecture Overview](#architecture-overview)
- [General Deployment Steps](#general-deployment-steps)
- [Cloud-Specific Instructions](#cloud-specific-instructions)
  - [Amazon Web Services (AWS)](#amazon-web-services-aws)
  - [Google Cloud Platform (GCP)](#google-cloud-platform-gcp)
  - [Microsoft Azure](#microsoft-azure)
- [Post-Deployment](#post-deployment)
  - [Verifying the Deployment](#verifying-the-deployment)
  - [Connecting to the Canton Console](#connecting-to-the-canton-console)
  - [Onboarding a New Tenant](#onboarding-a-new-tenant)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)

## Prerequisites

Before you begin, ensure you have the following tools installed and configured:

1.  **Git:** To clone the repository.
2.  **Terraform:** v1.3.0 or later.
3.  **kubectl:** To interact with the Kubernetes cluster.
4.  **Helm:** v3.8.0 or later.
5.  **Cloud Provider CLI:**
    *   **AWS:** `aws-cli` configured with credentials (`aws configure`).
    *   **GCP:** `gcloud` CLI, authenticated (`gcloud auth login`) and with a default project set (`gcloud config set project [PROJECT_ID]`).
    *   **Azure:** `az` CLI, authenticated (`az login`).

You will also need an account with your chosen cloud provider with sufficient permissions to create resources like Kubernetes clusters, VPCs, IAM roles, and KMS keys.

## Architecture Overview

The reference stack is composed of two main parts:

1.  **Infrastructure (Terraform):** Creates the foundational cloud resources.
    *   A Virtual Private Cloud (VPC) or Virtual Network (VNet) for network isolation.
    *   A managed Kubernetes cluster (EKS, GKE, or AKS).
    *   A Key Management Service (KMS) setup for tenant key segregation.
    *   IAM Roles or Service Accounts for secure, password-less access from Kubernetes to other cloud services.

2.  **Application (Helm):** Deploys Canton components onto the Kubernetes cluster.
    *   A dedicated `canton-validator` chart deploys a Canton validator node as a StatefulSet.
    *   Persistent Volumes for durable storage of the ledger state.
    *   Configuration that links the Canton instance to its dedicated KMS key for signing.
    *   (Optional) Monitoring hooks for Prometheus/Grafana.

## General Deployment Steps

1.  **Clone the Repository:**
    ```sh
    git clone https://github.com/your-org/canton-naas-reference-stack.git
    cd canton-naas-reference-stack
    ```

2.  **Follow Cloud-Specific Instructions:** The next steps for provisioning infrastructure and deploying the application are specific to each cloud provider. Please proceed to the relevant section below.

## Cloud-Specific Instructions

### Amazon Web Services (AWS)

#### 1. Provision Infrastructure with Terraform

Navigate to the AWS Terraform directory.

```sh
cd terraform/aws
```

Create a `terraform.tfvars` file by copying the example. This file will contain your specific configuration.

```sh
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set your desired values. At a minimum, you should review:

```hcl
# terraform.tfvars
aws_region   = "us-east-1"
project_name = "canton-naas-prod"
eks_cluster_version = "1.28"
```

Initialize and apply the Terraform configuration.

```sh
terraform init
terraform plan
terraform apply --auto-approve
```

This process can take 15-20 minutes. Once complete, Terraform will output the necessary information to connect to your new EKS cluster.

#### 2. Configure `kubectl`

Use the AWS CLI to configure `kubectl` to communicate with your new EKS cluster.

```sh
aws eks --region $(terraform output -raw aws_region) update-kubeconfig --name $(terraform output -raw eks_cluster_name)
```

Verify connectivity:

```sh
kubectl get nodes
```

#### 3. Deploy Canton with Helm

Navigate to the Helm chart directory.

```sh
cd ../../helm/canton-validator
```

Create a custom `values-aws.yaml` file to override default settings for your AWS deployment.

```yaml
# values-aws.yaml
persistence:
  storageClass: "gp2" # Or "gp3"

canton:
  config:
    # Use the KMS key ARN from Terraform output
    # Example format: "arn:aws:kms:us-east-1:123456789012:key/..."
    kmsKeyArn: "<PASTE_TERRAFORM_KMS_KEY_ARN_OUTPUT_HERE>"
```

You can get the KMS Key ARN from the Terraform output:

```sh
cd ../../terraform/aws
terraform output -raw validator_kms_key_arn
```

Now, install the Helm chart using your custom values file.

```sh
cd ../../helm/canton-validator

helm install canton-validator . -f values-aws.yaml --namespace canton-infra --create-namespace
```

### Google Cloud Platform (GCP)

#### 1. Provision Infrastructure with Terraform

Navigate to the GCP Terraform directory.

```sh
cd terraform/gcp
```

Create and customize your `terraform.tfvars` file.

```sh
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your GCP project details.

```hcl
# terraform.tfvars
project_id = "your-gcp-project-id"
region     = "us-central1"
zone       = "us-central1-c"
gke_cluster_version = "1.28"
```

Initialize and apply the Terraform configuration.

```sh
terraform init
terraform plan
terraform apply --auto-approve
```

#### 2. Configure `kubectl`

Configure `kubectl` to connect to your new GKE cluster.

```sh
gcloud container clusters get-credentials $(terraform output -raw gke_cluster_name) --region $(terraform output -raw region) --project $(terraform output -raw project_id)
```

Verify connectivity:

```sh
kubectl get nodes
```

#### 3. Deploy Canton with Helm

Navigate to the Helm chart directory.

```sh
cd ../../helm/canton-validator
```

Create a custom `values-gcp.yaml` file.

```yaml
# values-gcp.yaml
persistence:
  storageClass: "standard-rwo" # Standard persistent disk in GKE

# Required for Workload Identity
serviceAccount:
  create: true
  annotations:
    iam.gke.io/gcp-service-account: "<PASTE_GCP_SERVICE_ACCOUNT_EMAIL_HERE>"

canton:
  config:
    # Use the KMS Key Resource ID from Terraform output
    # Example format: "projects/p/locations/l/keyRings/r/cryptoKeys/k"
    kmsKeyId: "<PASTE_TERRAFORM_KMS_KEY_ID_OUTPUT_HERE>"
```

Get the required values from the Terraform output:

```sh
cd ../../terraform/gcp
terraform output -raw validator_kms_key_id
terraform output -raw validator_gcp_service_account_email
```

Install the Helm chart.

```sh
cd ../../helm/canton-validator

helm install canton-validator . -f values-gcp.yaml --namespace canton-infra --create-namespace
```

### Microsoft Azure

#### 1. Provision Infrastructure with Terraform

Navigate to the Azure Terraform directory.

```sh
cd terraform/azure
```

Create and customize your `terraform.tfvars` file.

```sh
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your Azure details.

```hcl
# terraform.tfvars
resource_group_name = "CantonNaaS-RG"
location            = "East US"
kubernetes_version  = "1.28"
```

Initialize and apply the Terraform configuration.

```sh
terraform init
terraform plan
terraform apply --auto-approve
```

#### 2. Configure `kubectl`

Configure `kubectl` to connect to your new AKS cluster.

```sh
az aks get-credentials --resource-group $(terraform output -raw resource_group_name) --name $(terraform output -raw aks_cluster_name)
```

Verify connectivity:

```sh
kubectl get nodes
```

#### 3. Deploy Canton with Helm

Navigate to the Helm chart directory.

```sh
cd ../../helm/canton-validator
```

Create a custom `values-azure.yaml` file. Note the specific configuration required for Azure Key Vault and Workload Identity.

```yaml
# values-azure.yaml
persistence:
  storageClass: "managed-csi" # Standard Azure Disk

# Required for Azure Workload Identity
serviceAccount:
  create: true
  name: "canton-validator-sa"
  annotations:
    azure.workload.identity/client-id: "<PASTE_USER_ASSIGNED_IDENTITY_CLIENT_ID_HERE>"

canton:
  config:
    # Use the Key Vault Key ID from Terraform output
    # Example format: "https://mykeyvault.vault.azure.net/keys/my-key/..."
    keyVaultKeyId: "<PASTE_TERRAFORM_KEY_VAULT_KEY_ID_OUTPUT_HERE>"
    # Use the Key Vault URL
    keyVaultUrl: "<PASTE_TERRAFORM_KEY_VAULT_URL_HERE>"
```

Get the required values from the Terraform output:

```sh
cd ../../terraform/azure
terraform output -raw validator_identity_client_id
terraform output -raw key_vault_key_id
terraform output -raw key_vault_url
```

Install the Helm chart.

```sh
cd ../../helm/canton-validator

helm install canton-validator . -f values-azure.yaml --namespace canton-infra --create-namespace
```

## Post-Deployment

### Verifying the Deployment

Check the status of the pods in the `canton-infra` namespace.

```sh
kubectl get pods -n canton-infra
```

You should see a pod named `canton-validator-0` in the `Running` state. It may take a few minutes to pull the image and start up. If it's not running, check the logs:

```sh
kubectl logs canton-validator-0 -n canton-infra
```

### Connecting to the Canton Console

To interact with your Canton validator node for administrative tasks, you can port-forward the admin API port.

```sh
kubectl port-forward svc/canton-validator 5012:5012 -n canton-infra
```

Now you can connect to `localhost:5012` using the Canton Console or client libraries.

### Onboarding a New Tenant

The reference stack is designed for multi-tenancy. Onboarding a new tenant typically involves:

1.  **Create Tenant Infrastructure:** Run a dedicated Terraform module (e.g., `terraform/modules/tenant`) to provision a new KMS key and IAM role/service account for the tenant.
2.  **Deploy Tenant Participant Node:** Deploy a new instance of a Canton participant using a separate Helm chart. This Helm release would be configured with the new tenant's KMS key and service account, ensuring cryptographic and access isolation.

## Troubleshooting

-   **Terraform Apply Fails:** Check the error messages. Most failures are due to insufficient cloud provider permissions or invalid variable values in `terraform.tfvars`.
-   **Pod is in `Pending` state:** The cluster may not have enough resources (CPU/memory) or available Persistent Volumes. Use `kubectl describe pod <pod-name> -n canton-infra` to see events and diagnose the issue.
-   **Pod is in `CrashLoopBackOff`:** The Canton process is failing to start. Check the logs (`kubectl logs ...`) for configuration errors, especially related to KMS key access. Ensure the IAM roles and service account permissions are correctly configured.
-   **Helm Install Fails:** Common issues include typos in `values.yaml` files or incorrect `kubeconfig`. Use `helm lint .` to check for chart issues.

## Cleanup

To avoid ongoing charges, destroy all the resources you've created.

1.  **Delete the Helm Release:**
    ```sh
    helm uninstall canton-validator -n canton-infra
    ```

2.  **Destroy the Infrastructure:**
    Navigate to the cloud provider's Terraform directory (`terraform/aws`, `terraform/gcp`, or `terraform/azure`) and run:
    ```sh
    terraform destroy --auto-approve
    ```

This will delete the Kubernetes cluster and all associated resources.