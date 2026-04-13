#!/bin/bash
#
# End-to-end validation script for a deployed Canton NaaS stack.
#
# This script performs the following checks:
# 1. Verifies required command-line tools are installed.
# 2. Checks the health of Kubernetes pods in the target namespace.
# 3. Checks the health endpoint of the deployed Canton Participant node.
# 4. Compiles a simple Daml model (PingPong).
# 5. Uses Daml Script to run a multi-party transaction on the participant, verifying:
#    - Party allocation
#    - DAR upload
#    - Contract creation and exercise
#
# Usage:
#   export NAAS_ADMIN_JWT="your-jwt-token"
#   ./validate-deployment.sh --namespace canton-enterprise --participant-grpc-url participant1.naas.my-domain.com:443

set -euo pipefail

# --- Configuration ---
DEFAULT_NAMESPACE="canton-enterprise"
TEMP_DIR=""

# --- Colors ---
COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'

# --- Helper Functions ---
info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"
}

success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"
}

warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"
}

error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1" >&2
    exit 1
}

check_tool() {
    if ! command -v "$1" &> /dev/null; then
        error "Required tool '$1' is not installed. Please install it and try again."
    fi
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        info "Cleaning up temporary resources..."
        rm -rf "$TEMP_DIR"
        info "Removed temporary directory: $TEMP_DIR"
    fi
}
trap cleanup EXIT

# --- Argument Parsing ---
NAMESPACE="${DEFAULT_NAMESPACE}"
K8S_CONTEXT=""
PARTICIPANT_GRPC_URL=""
TLS_ENABLED=true

print_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -n, --namespace <ns>         Kubernetes namespace where Canton is deployed (default: ${DEFAULT_NAMESPACE})"
    echo "  -c, --context <ctx>          Kubernetes context to use (optional)"
    echo "  -p, --participant-grpc-url <url> Participant gRPC URL (host:port). Required."
    echo "  --no-tls                     Disable TLS for gRPC connection."
    echo "  -h, --help                   Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  NAAS_ADMIN_JWT               A valid JWT for an admin user of the participant node. Required."
}


while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -n|--namespace)
        NAMESPACE="$2"
        shift 2
        ;;
        -c|--context)
        K8S_CONTEXT="$2"
        shift 2
        ;;
        -p|--participant-grpc-url)
        PARTICIPANT_GRPC_URL="$2"
        shift 2
        ;;
        --no-tls)
        TLS_ENABLED=false
        shift
        ;;
        -h|--help)
        print_help
        exit 0
        ;;
        *)
        error "Unknown option: $1"
        ;;
    esac
done

# --- Main Script ---
info "Starting Canton NaaS deployment validation..."
info "--------------------------------------------"
info "Namespace:           ${NAMESPACE}"
info "K8s Context:         ${K8S_CONTEXT:-default}"
info "Participant gRPC URL:  ${PARTICIPANT_GRPC_URL}"
info "TLS Enabled:         ${TLS_ENABLED}"
info "--------------------------------------------"

# --- 1. Pre-flight Checks ---
section_header="1. PRE-FLIGHT CHECKS"
info "${section_header}"

check_tool "dpm"
check_tool "kubectl"
check_tool "jq"
check_tool "curl"

if [[ -z "${NAAS_ADMIN_JWT:-}" ]]; then
    error "Environment variable NAAS_ADMIN_JWT is not set. A valid admin token is required."
fi
if [[ -z "${PARTICIPANT_GRPC_URL}" ]]; then
    error "--participant-grpc-url is a required argument."
fi

KUBECTL_OPTS=""
if [[ -n "${K8S_CONTEXT}" ]]; then
    KUBECTL_OPTS="--context ${K8S_CONTEXT}"
fi

success "All required tools are installed and configuration is present."

# --- 2. Kubernetes Health Check ---
section_header="2. KUBERNETES HEALTH CHECK"
info "${section_header}"

info "Fetching pod status from namespace '${NAMESPACE}'..."
POD_STATUS=$(kubectl ${KUBECTL_OPTS} -n "${NAMESPACE}" get pods -o json)

if ! echo "${POD_STATUS}" | jq -e '.items | length > 0' > /dev/null; then
    error "No pods found in namespace '${NAMESPACE}'. Is the deployment running?"
fi

# Check for non-running pods
NON_RUNNING_PODS=$(echo "${POD_STATUS}" | jq -r '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | .metadata.name')
if [[ -n "${NON_RUNNING_PODS}" ]]; then
    error "Found pods not in 'Running' state:\n${NON_RUNNING_PODS}"
fi

# Check for high restart counts
RESTARTING_PODS=$(echo "${POD_STATUS}" | jq -r '[.items[] | .status.containerStatuses[]? | select(.restartCount > 3)] | .[] | .name' | uniq)
if [[ -n "${RESTARTING_PODS}" ]]; then
    warn "The following containers have a high restart count (>3), which may indicate a problem:"
    kubectl ${KUBECTL_OPTS} -n "${NAMESPACE}" get pods -o wide | grep -E "$(echo ${RESTARTING_PODS} | tr ' ' '|')"
else
    info "No containers with high restart counts detected."
fi

success "All pods in namespace '${NAMESPACE}' are in 'Running' state."

# --- 3. Participant Node Health Check ---
section_header="3. PARTICIPANT NODE HEALTH CHECK"
info "${section_header}"

HTTP_SCHEME="https"
if [[ "${TLS_ENABLED}" == "false" ]]; then
    HTTP_SCHEME="http"
fi
PARTICIPANT_HOST=$(echo "${PARTICIPANT_GRPC_URL}" | cut -d: -f1)
PARTICIPANT_HEALTH_URL="${HTTP_SCHEME}://${PARTICIPANT_HOST}/health"
info "Pinging participant health endpoint: ${PARTICIPANT_HEALTH_URL}"

# Use --insecure for self-signed certs in test environments. A production NaaS should have valid certs.
HEALTH_RESPONSE=$(curl --insecure -s -f -L "${PARTICIPANT_HEALTH_URL}") || error "Failed to connect to participant health endpoint at ${PARTICIPANT_HEALTH_URL}. Check URL and network connectivity."

IS_HEALTHY=$(echo "${HEALTH_RESPONSE}" | jq -r '.healthy')

if [[ "${IS_HEALTHY}" != "true" ]]; then
    error "Participant node reports as unhealthy. Response:\n${HEALTH_RESPONSE}"
fi

success "Participant node is healthy."

# --- 4. DAML E2E WORKFLOW TEST ---
section_header="4. DAML E2E WORKFLOW TEST"
info "${section_header}"

# Setup temporary Daml project
TEMP_DIR=$(mktemp -d)
info "Creating temporary Daml project in ${TEMP_DIR}"
cd "${TEMP_DIR}"

# a. Create daml.yaml
cat > daml.yaml << EOL
sdk-version: 3.4.0
name: validation-test
version: 0.1.0
source: daml
dependencies:
  - daml-prim
  - daml-stdlib
  - daml-script
EOL

mkdir -p daml

# b. Create Daml model (PingPong)
cat > daml/Main.daml << EOL
module Main where

import Daml.Script
import DA.Time (getTime)
import DA.Date (unsafeFromTimestamp)

template Ping
  with
    sender: Party
    receiver: Party
    count: Int
  where
    signatory sender
    observer receiver

    choice Pong: ContractId Pong
      controller receiver
      do
        create Pong with sender = receiver, receiver = sender, count = count + 1

template Pong
  with
    sender: Party
    receiver: Party
    count: Int
  where
    signatory sender
    observer receiver

    choice Ping: ContractId Ping
      controller receiver
      do
        create Ping with sender = receiver, receiver = sender, count = count + 1

-- Daml Script for validation
pingPongTest: Script ()
pingPongTest = script do
  -- Use unique names to avoid clashes on subsequent runs
  now <- getTime
  let operatorHint = "ValidatorOperator-" <> show (round (1000000.0 * (unsafeFromTimestamp now)))
  let clientHint = "TestClient-" <> show (round (1000000.0 * (unsafeFromTimestamp now)))

  operator <- allocatePartyWithHint (PartyIdHint operatorHint) (DisplayName "ValidatorOperator")
  client <- allocatePartyWithHint (PartyIdHint clientHint) (DisplayName "TestClient")

  pingCid0 <- submit operator do
    createCmd Ping with sender = operator, receiver = client, count = 0
  
  (pingCid, _ping) <- queryContractId client pingCid0

  pongCid <- submit client do
    exerciseCmd pingCid Pong

  pingCid2 <- submit operator do
    exerciseCmd pongCid Ping

  -- Final state check
  Some ping2 <- queryContractId operator pingCid2
  assertMsg "Final ping count should be 2" (ping2.count == 2)

  pure ()
EOL

# c. Build the DAR
info "Building validation DAR..."
dpm build

# d. Prepare for Daml Script execution
TOKEN_FILE="${TEMP_DIR}/admin.jwt"
echo -n "${NAAS_ADMIN_JWT}" > "${TOKEN_FILE}"

DAR_PATH=".daml/dist/validation-test-0.1.0.dar"
PARTICIPANT_HOST=$(echo "${PARTICIPANT_GRPC_URL}" | cut -d: -f1)
PARTICIPANT_PORT=$(echo "${PARTICIPANT_GRPC_URL}" | cut -d: -f2)

DAML_SCRIPT_OPTS=(
    --dar "${DAR_PATH}"
    --script-name "Main:pingPongTest"
    --ledger-host "${PARTICIPANT_HOST}"
    --ledger-port "${PARTICIPANT_PORT}"
    --access-token-file "${TOKEN_FILE}"
)

if [[ "${TLS_ENABLED}" == "true" ]]; then
    DAML_SCRIPT_OPTS+=(--tls)
fi

# e. Run the Daml Script
info "Executing Daml Script against participant ${PARTICIPANT_GRPC_URL}..."
info "This will allocate parties, upload the DAR, and run a multi-party transaction."
if ! dpm script "${DAML_SCRIPT_OPTS[@]}"; then
    error "Daml Script execution failed. This indicates a problem with the Canton participant's ability to process transactions."
fi

success "Daml Script executed successfully. The participant processed the multi-party workflow correctly."

# --- Final Summary ---
echo
echo -e "${COLOR_GREEN}=====================================================${COLOR_RESET}"
echo -e "${COLOR_GREEN}  NAaS Deployment Validation Successful!             ${COLOR_RESET}"
echo -e "${COLOR_GREEN}=====================================================${COLOR_RESET}"
echo "All checks passed:"
echo "  ✅ Pre-flight checks"
echo "  ✅ Kubernetes pod health"
echo "  ✅ Participant node health endpoint"
echo "  ✅ End-to-end Daml workflow (party allocation, DAR upload, transaction)"
echo
info "The Canton NaaS stack appears to be fully operational."