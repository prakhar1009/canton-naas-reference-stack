#!/bin/bash
#
# Canton NaaS Reference Stack Bootstrap Script
#
# This script automates the end-to-end setup of a Canton Network-as-a-Service
# environment on a supported cloud provider. It orchestrates Terraform for
# infrastructure provisioning and Helm for deploying Canton components onto
# a Kubernetes cluster.
#
# Usage:
#   ./scripts/bootstrap-naas.sh [OPTIONS]
#
# Options:
#   --provider <provider>   Cloud provider to use. Supported: 'aws', 'gcp', 'azure'. (Default: 'aws')
#   --region <region>       Cloud provider region to deploy into. (e.g., 'us-east-1')
#   --env <name>            Deployment environment name. (e.g., 'dev', 'prod'). (Default: 'dev')
#   --help                  Display this help message.
#
# Prerequisites:
#   - Terraform CLI (>= 1.5)
#   - Helm CLI (>= 3.10)
#   - kubectl CLI
#   - Cloud provider CLI (aws, gcloud, or az) authenticated with sufficient permissions.
#

set -euo pipefail

# --- Configuration ---
# Default values can be overridden by command-line options
PROVIDER="aws"
REGION=""
ENV_NAME="dev"

# --- Script Setup ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${REPO_ROOT}/terraform"
HELM_DIR="${REPO_ROOT}/helm"
KUBECONFIG_PATH="${HOME}/.kube/config.${ENV_NAME}.${PROVIDER}"

# --- Helper Functions ---
# Shell colors for logging
readonly COLOR_RESET="\033[0m"
readonly COLOR_RED="\033[0;31m"
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[0;33m"
readonly COLOR_CYAN="\033[0;36m"

log_info() {
    echo -e "${COLOR_CYAN}[INFO] ${1}${COLOR_RESET}"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS] ${1}${COLOR_RESET}"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN] ${1}${COLOR_RESET}"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR] ${1}${COLOR_RESET}" >&2
    exit 1
}

check_dep() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required dependency '$1' is not installed. Please install it and ensure it's in your PATH."
    fi
}

usage() {
    cat <<EOF
Canton NaaS Reference Stack Bootstrap Script

This script automates the setup of a Canton NaaS environment.

Usage:
  $0 [OPTIONS]

Options:
  --provider <provider>   Cloud provider. Supported: 'aws', 'gcp', 'azure'. (Default: 'aws')
  --region <region>       Cloud provider region. (Required)
  --env <name>            Deployment environment name. (Default: 'dev')
  --help                  Display this help message.

Example:
  $0 --provider aws --region us-east-1 --env staging
EOF
    exit 0
}

# --- Main Logic ---

main() {
    # 1. Parse Arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider)
                PROVIDER="$2"
                shift 2
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --env)
                ENV_NAME="$2"
                shift 2
                ;;
            --help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                ;;
        esac
    done

    # 2. Validate Inputs
    if [[ -z "${REGION}" ]]; then
        log_error "Region is required. Please specify with --region."
    fi

    case "${PROVIDER}" in
        aws|gcp|azure)
            # valid provider
            ;;
        *)
            log_error "Unsupported provider '${PROVIDER}'. Supported providers are 'aws', 'gcp', 'azure'."
            ;;
    esac

    log_info "Starting Canton NaaS bootstrap for environment '${ENV_NAME}' on '${PROVIDER}' in region '${REGION}'..."

    # 3. Check Dependencies
    log_info "Checking for required dependencies..."
    check_dep "terraform"
    check_dep "helm"
    check_dep "kubectl"
    check_dep "${PROVIDER}" # Check for aws, gcloud, or az CLI

    # 4. Provision Infrastructure with Terraform
    log_info "Step 1/5: Provisioning core infrastructure with Terraform..."
    cd "${TERRAFORM_DIR}"

    # Ensure we use the correct workspace for the environment
    if ! terraform workspace list | grep -q "${ENV_NAME}"; then
        log_info "Creating new Terraform workspace: ${ENV_NAME}"
        terraform workspace new "${ENV_NAME}"
    else
        terraform workspace select "${ENV_NAME}"
    fi

    log_info "Initializing Terraform..."
    terraform init -upgrade

    log_info "Applying Terraform plan..."
    terraform apply -auto-approve \
        -var="region=${REGION}" \
        -var="env=${ENV_NAME}" \
        -var="provider=${PROVIDER}"

    # 5. Configure kubectl
    log_info "Step 2/5: Configuring kubectl to connect to the new Kubernetes cluster..."
    export KUBECONFIG="${KUBECONFIG_PATH}"
    mkdir -p "$(dirname "${KUBECONFIG_PATH}")"

    CLUSTER_NAME=$(terraform output -raw kubernetes_cluster_name)
    case "${PROVIDER}" in
        aws)
            aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}"
            ;;
        gcp)
            gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}"
            mv "${HOME}/.kube/config" "${KUBECONFIG_PATH}"
            ;;
        azure)
            RESOURCE_GROUP=$(terraform output -raw resource_group_name)
            az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --file "${KUBECONFIG_PATH}"
            ;;
    esac

    log_info "Waiting for Kubernetes API server to be ready..."
    until kubectl get nodes &> /dev/null; do
        log_info "  ... still waiting"
        sleep 5
    done
    log_success "kubectl is configured and connected to cluster '${CLUSTER_NAME}'."

    # 6. Deploy Canton Domain Components
    log_info "Step 3/5: Deploying Canton Domain components via Helm..."
    helm repo add digital-asset https://digital-asset.github.io/daml-helm-charts
    helm repo update

    # In a real NaaS, these values would come from a secure source
    DOMAIN_ID="naas-ref-domain-$(echo "${ENV_NAME}" | tr '[:upper:]' '[:lower:]')"
    DOMAIN_NAMESPACE="canton-domain"

    kubectl create namespace "${DOMAIN_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install canton-domain-sequencer digital-asset/canton-sequencer \
        --namespace "${DOMAIN_NAMESPACE}" \
        --version 3.4.0 \
        --set "domain.id=${DOMAIN_ID}" \
        --wait

    helm upgrade --install canton-domain-mediator digital-asset/canton-mediator \
        --namespace "${DOMAIN_NAMESPACE}" \
        --version 3.4.0 \
        --set "domain.id=${DOMAIN_ID}" \
        --wait

    # 7. Deploy Sample Tenant Validators
    log_info "Step 4/5: Deploying sample Tenant Validator nodes..."
    for tenant in "acme-corp" "globex-inc"; do
        log_info "  Deploying validator for tenant: ${tenant}"
        local tenant_namespace="tenant-${tenant}"
        local release_name="validator-${tenant}"

        kubectl create namespace "${tenant_namespace}" --dry-run=client -o yaml | kubectl apply -f -

        # Here we use the local chart from the repository
        helm upgrade --install "${release_name}" "${HELM_DIR}/canton-validator" \
            --namespace "${tenant_namespace}" \
            --set "tenant.id=${tenant}" \
            --set "canton.domain.id=${DOMAIN_ID}" \
            --set "canton.domain.sequencerUrl=http://canton-domain-sequencer.${DOMAIN_NAMESPACE}.svc.cluster.local:5011" \
            --wait
    done

    # 8. Deploy Monitoring & Dashboard (Placeholder)
    log_info "Step 5/5: Deploying Monitoring Stack and NaaS Dashboard..."
    # This section would typically deploy Prometheus, Grafana, and a custom dashboard.
    # For this reference script, we'll just log the intent.
    log_warn "  Monitoring and dashboard deployment is a placeholder. See docs/MONITORING.md for setup guides."

    # --- Final Output ---
    log_success "Canton NaaS Bootstrap Complete!"
    echo -e "------------------------------------------------------------------"
    echo -e "${COLOR_GREEN}Environment '${ENV_NAME}' is ready.${COLOR_RESET}"
    echo
    echo -e "To interact with the cluster, use:"
    echo -e "  export KUBECONFIG=${KUBECONFIG_PATH}"
    echo
    echo -e "Canton Domain ID: ${COLOR_YELLOW}${DOMAIN_ID}${COLOR_RESET}"
    echo
    echo -e "Sample Tenant Validators:"
    kubectl get pods --all-namespaces -l app.kubernetes.io/component=validator
    echo
    echo -e "To get the external IP for a validator (e.g., acme-corp), run:"
    echo -e "  kubectl get svc validator-acme-corp -n tenant-acme-corp"
    echo
    echo -e "${COLOR_YELLOW}To tear down the entire environment, navigate to the '${TERRAFORM_DIR}' directory,"
    echo -e "select the '${ENV_NAME}' workspace, and run 'terraform destroy'.${COLOR_RESET}"
    echo -e "------------------------------------------------------------------"
}

# --- Script Execution ---
main "$@"