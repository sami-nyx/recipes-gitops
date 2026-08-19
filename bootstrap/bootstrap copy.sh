#!/bin/bash
set -euo pipefail

# ==============================================================================
# CONFIGURATION & PATHS
# ==============================================================================
# TF_DIR="/home/sami/projects/recipes-infra/eks-platform-terraform"
# GITOPS_REPO_URL="https://github.com/sami-nyx/recipes-gitops.git"====================================================><><><><><><><><><><><><><>

# Chart Versions
ESO_VERSION=" 2.9.0 "          
ARGOCD_CHART_VERSION="10.4.0"   

# ==============================================================================
# PRETTY LOGGING FUNCTIONS
# ==============================================================================
COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"    # Blue
COLOR_SUCCESS="\033[1;32m" # Green
COLOR_WARN="\033[1;33m"    # Yellow
COLOR_ERROR="\033[1;31m"   # Red

log_info() {
    echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $1"
}

log_success() {
    echo -e "${COLOR_SUCCESS}[SUCCESS]${COLOR_RESET} $1"
}

log_warn() {
    echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $1"
}

log_error() {
    echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $1"
    exit 1
}

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================
log_info "Running pre-flight checks..."
for cmd in  envsubst helm kubectl aws; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required tool '$cmd' is not installed or not in PATH."
    fi
done

if [ ! -d "$TF_DIR" ]; then
    log_error "Terraform directory not found at: $TF_DIR"
fi

log_success "All required CLI tools are present."

# ==============================================================================
# TERRAFORM OUTPUT EXTRACTION
# ==============================================================================
# log_info "Fetching outputs from Terraform state..."
# TF_OUTPUTS=$(terraform -chdir="$TF_DIR" output -json) || log_error "Failed to run terraform output."

# export CLUSTER_REGION=$(echo "$TF_OUTPUTS" | jq -r ".cluster_region.value // empty")
# export CLUSTER_NAME=$(echo "$TF_OUTPUTS" | jq -r ".cluster_name.value // empty")
# export EXTERNAL_SECRETS_ROLE_ARN=$(echo "$TF_OUTPUTS" | jq -r ".external_secrets_role_arn.value // empty")

if [[ -z "$CLUSTER_REGION" || -z "$CLUSTER_NAME" || -z "$EXTERNAL_SECRETS_ROLE_ARN" ]]; then
    log_error "One or more required Terraform outputs are missing or empty."
fi

log_success "Target Cluster: $CLUSTER_NAME ($CLUSTER_REGION)"
log_success "External Secrets IAM Role resolved."

# ==============================================================================
# KUBECONFIG UPDATE
# ==============================================================================
log_info "Updating local kubeconfig for EKS cluster..."
aws eks update-kubeconfig --region "$CLUSTER_REGION" --name "$CLUSTER_NAME" &> /dev/null
log_success "Kubeconfig updated successfully."

# ==============================================================================
# HELM REPOSITORIES SETUP
# ==============================================================================
log_info "Configuring Helm repositories..."
helm repo add external-secrets https://charts.external-secrets.io &> /dev/null
helm repo add argocd https://argoproj.github.io/argo-helm &> /dev/null
helm repo update &> /dev/null
log_success "Helm repositories updated."

# ==============================================================================
# EXTERNAL SECRETS OPERATOR (ESO) DEPLOYMENT
# ==============================================================================
log_info "Installing External Secrets Operator (v$ESO_VERSION)..."
envsubst < ./values/external-secrets-operator.yaml | \
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "$ESO_VERSION" \
  --namespace external-secrets \
  --create-namespace \
  --values -

log_info "Waiting for External Secrets CRDs to be established..."
kubectl wait --for=condition=established --timeout=90s crd/clustersecretstores.external-secrets.io
log_success "External Secrets Operator is ready."

# ==============================================================================
# CLUSTER SECRET STORE & SECRETS SETUP
# ==============================================================================
log_info "Deploying ClusterSecretStore..."
envsubst < ./manifests/cluster-secret-store.yaml | kubectl apply -f -

log_info "Ensuring namespace 'argocd' exists..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

log_info "Deploying Argo CD GitHub Repository Secret..."
envsubst < ./manifests/argocd-github-secret.yaml | kubectl apply -f -
log_success "Cluster secrets and credentials configured."

# ==============================================================================
# ARGO CD INSTALLATION
# ==============================================================================
log_info "Installing Argo CD (v$ARGOCD_CHART_VERSION)..."
helm upgrade --install argocd argocd/argo-cd \
  --namespace argocd \
  --version "$ARGOCD_CHART_VERSION"

log_success "Argo CD installed successfully!"
echo -e "\n------------------------------------------------------------"
log_success "Bootstrap scaffolding complete! Argo CD is now taking over."
echo -e "------------------------------------------------------------\n"