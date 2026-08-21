#!/bin/bash
set -euo pipefail

ESO_VERSION="2.9.0"
ARGOCD_CHART_VERSION="10.4.0"

COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"
COLOR_SUCCESS="\033[1;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[1;31m"

log_info() {
    echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $1"
}

log_success() {
    echo -e "${COLOR_SUCCESS}[SUCCESS]${COLOR_RESET} $1"
}

log_error() {
    echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $1"
    exit 1
}

log_info "Running pre-flight checks..."

for cmd in jq envsubst helm kubectl aws; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required tool '$cmd' is not installed."
    fi
done

: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${CLUSTER_REGION:?CLUSTER_REGION is required}"
: "${EXTERNAL_SECRETS_ROLE_ARN:?EXTERNAL_SECRETS_ROLE_ARN is required}"
: "${GITOPS_REPO_URL:?GITOPS_REPO_URL is required}"

log_success "Cluster: $CLUSTER_NAME"
log_success "Region:  $CLUSTER_REGION"
log_success "External Secrets role resolved."

log_info "Updating kubeconfig..."

aws eks update-kubeconfig \
    --region "$CLUSTER_REGION" \
    --name "$CLUSTER_NAME"

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
log_success "Kubeconfig updated."

log_info "Configuring Helm repositories..."

helm repo add external-secrets https://charts.external-secrets.io
helm repo add argocd https://argoproj.github.io/argo-helm
helm repo update

log_success "Helm repositories updated."

log_info "Installing External Secrets Operator..."

helm upgrade --install external-secrets \
    external-secrets/external-secrets \
    --version "$ESO_VERSION" \
    --namespace external-secrets \
    --create-namespace \
    --values <(envsubst < ./values/external-secrets-operator.yaml)

log_info "Waiting for External Secrets CRDs..."

kubectl wait \
    --for=condition=established \
    --timeout=90s \
    crd/clustersecretstores.external-secrets.io
log_info "Waiting for External Secrets webhook endpoints to be ready..."
while [ -z "$(kubectl get endpoints external-secrets-webhook -n external-secrets -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)" ]; do
    echo "Waiting for webhook endpoints..."
    sleep 2
done

log_success "External Secrets Operator is ready."

log_info "Deploying ClusterSecretStore..."

envsubst < ./manifests/cluster-secret-store.yaml | kubectl apply -f -

log_info "Ensuring Argo CD namespace exists..."

kubectl create namespace argocd \
    --dry-run=client \
    -o yaml | kubectl apply -f -

log_info "Deploying Argo CD GitHub repository secret..."

envsubst < ./manifests/argocd-github-secret.yaml | kubectl apply -f -

log_success "Cluster secrets configured."

log_info "Installing Argo CD..."

helm upgrade --install argocd \
    argocd/argo-cd \
    --namespace argocd \
    --version "$ARGOCD_CHART_VERSION"

log_info "Deploying Argo CD App Of Apps"
kubectl apply -f ./root-app.yaml

log_success "Bootstrap complete."