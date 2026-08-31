#!/bin/bash
set -euo pipefail

# Local stand-in for recipes-aws-infra's tf-apply-eks.yaml bootstrap-cluster
# job - for when you don't want to (or, out of free-tier Actions minutes,
# can't) run it through GitHub Actions. Reads the same three values that job
# pulls from `needs.terraform-apply.outputs` (cluster_name, cluster_region,
# external_secrets_role_arn) straight out of local `terraform output`
# against a recipes-aws-infra clone instead, sets the exact env vars
# bootstrap.sh expects, and runs it.
#
# Unlike CI, this does not assume the github-actions-bootstrap role - it
# just uses whatever AWS credentials are already active in this shell. That
# only works if the active identity is itself an EKS access entry principal
# with cluster-admin (i.e. the principal_arn value from terraform.tfvars -
# your own IAM user, for a solo/local setup - already is one; nothing extra
# to configure).
#
# Prerequisites: `terraform apply` already completed successfully against
# recipes-aws-infra's terraform/eks-platform.
#
# Usage: ./bootstrap_local.sh <path-to-local-recipes-aws-infra-clone> [confirm_rebootstrap]

INFRA_DIR="${1:?Usage: $0 <path-to-local-recipes-aws-infra-clone> [confirm_rebootstrap]}"
CONFIRM_REBOOTSTRAP="${2:-false}"

TF_DIR="$INFRA_DIR/terraform/eks-platform"

if [ ! -d "$TF_DIR" ]; then
    echo "Error: '$TF_DIR' not found - is '$INFRA_DIR' a recipes-aws-infra clone?" >&2
    exit 1
fi

echo "Active AWS identity:"
aws sts get-caller-identity --query "Arn" --output text

echo "Reading terraform outputs from $TF_DIR..."

CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw cluster_name)"
CLUSTER_REGION="$(terraform -chdir="$TF_DIR" output -raw cluster_region)"
EXTERNAL_SECRETS_ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw external_secrets_role_arn)"

echo "Cluster:               $CLUSTER_NAME ($CLUSTER_REGION)"
echo "External Secrets role: $EXTERNAL_SECRETS_ROLE_ARN"

export CLUSTER_NAME
export CLUSTER_REGION
export EXTERNAL_SECRETS_ROLE_ARN
export GITOPS_REPO_URL="https://github.com/sami-nyx/recipes-gitops.git"
export CONFIRM_REBOOTSTRAP

cd "$(dirname "${BASH_SOURCE[0]}")"
./bootstrap.sh
