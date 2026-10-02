#!/bin/bash

set -e

# ============================================================
# Usage
# ============================================================

if [ "$#" -ne 3 ]; then
    echo "Usage:"
    echo "  $0 <scanning_subscription_id> <dspm_region> <integration_name>"
    echo ""
    echo "Example:"
    echo "  $0 12345678-1234-1234-1234-123456789abc \"East US\" azure-dspm"
    exit 1
fi

SCANNING_SUBSCRIPTION_ID="$1"
DSPM_REGION="$2"
INTEGRATION_NAME="$3"

SERVICE_PRINCIPAL_NAME="${INTEGRATION_NAME}-sp"

BASE_DIR="$HOME/tmp/dspm"
SP_DIR="$BASE_DIR/service-principal"
DEPLOY_DIR="$BASE_DIR/deployment"

echo "============================================================"
echo "Lacework Azure DSPM Deployment"
echo "============================================================"
echo "Scanning Subscription : $SCANNING_SUBSCRIPTION_ID"
echo "DSPM Region           : $DSPM_REGION"
echo "Integration Name      : $INTEGRATION_NAME"
echo "Service Principal     : $SERVICE_PRINCIPAL_NAME"
echo "============================================================"
echo ""

# ============================================================
# Phase 1 - Prepare Service Principal Terraform
# ============================================================

mkdir -p "$SP_DIR"
cd "$SP_DIR"

if [ ! -d "terraform-azure-dspm" ]; then
    echo "Cloning Lacework Terraform repository..."

    git clone https://github.com/lacework/terraform-azure-dspm.git
fi

cp terraform-azure-dspm/service-principal/example/main.tf .

echo ""
echo "Initializing Service Principal Terraform..."
terraform init

echo ""
echo "Creating Azure Service Principal..."

terraform apply -auto-approve \
    -var="scanning_subscription_id=$SCANNING_SUBSCRIPTION_ID" \
    -var="service_principal_name=$SERVICE_PRINCIPAL_NAME"

# ============================================================
# Phase 2 - Retrieve Service Principal credentials
# ============================================================

echo ""
echo "Retrieving Service Principal credentials..."

export ARM_CLIENT_ID=$(terraform output -raw example_service_principal_client_id)
export ARM_CLIENT_SECRET=$(terraform output -raw example_service_principal_client_secret)
export ARM_TENANT_ID=$(terraform output -raw example_service_principal_tenant_id)
export ARM_SUBSCRIPTION_ID="$SCANNING_SUBSCRIPTION_ID"

echo ""
echo "Service Principal created."
echo "ARM_CLIENT_ID : $ARM_CLIENT_ID"
echo "ARM_TENANT_ID : $ARM_TENANT_ID"
echo "ARM_SUBSCRIPTION_ID : $ARM_SUBSCRIPTION_ID"
echo "ARM_CLIENT_SECRET : <hidden>"

# ============================================================
# Phase 3 - Create DSPM Terraform configuration
# ============================================================

mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

cat > main.tf <<EOF
terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }

    lacework = {
      source = "lacework/lacework"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "lacework" {}

module "lacework_azure_dspm" {
  source  = "lacework/dspm/azure"
  version = "~> 0.1"

  lacework_integration_name = "$INTEGRATION_NAME"

  regions = ["$DSPM_REGION"]

  scanning_subscription_id = "/subscriptions/$SCANNING_SUBSCRIPTION_ID"
}
EOF

# ============================================================
# Phase 4 - Deploy DSPM
# ============================================================

echo ""
echo "Initializing DSPM Terraform..."

terraform init

echo ""
echo "Creating DSPM deployment plan..."

terraform plan

echo ""
echo "Deploying Lacework DSPM..."

terraform apply -auto-approve

# ============================================================
# Complete
# ============================================================

echo ""
echo "============================================================"
echo "Lacework DSPM deployment completed"
echo "============================================================"
echo "Integration : $INTEGRATION_NAME"
echo "Region      : $DSPM_REGION"
echo "Subscription: $SCANNING_SUBSCRIPTION_ID"
echo "============================================================"
