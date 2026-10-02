#!/bin/bash

set -e

# Check arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <scanning_subscription_id> <dspm_region> <integration_name>"
    echo ""
    echo "Example:"
    echo "  $0 12345678-1234-1234-1234-123456789abc \"East US\" azure-dspm"
    exit 1
fi

SCANNING_SUBSCRIPTION_ID="$1"
DSPM_REGION="$2"
INTEGRATION_NAME="$3"

# Check Azure credentials
if [ -z "$ARM_CLIENT_ID" ] || \
   [ -z "$ARM_CLIENT_SECRET" ] || \
   [ -z "$ARM_TENANT_ID" ] || \
   [ -z "$ARM_SUBSCRIPTION_ID" ]; then
    echo "ERROR: Azure ARM credentials are not set."
    echo "Run:"
    echo "  source ./create-dspm-sp.sh"
    exit 1
fi

# Create deployment directory
mkdir -p ~/tmp/dspm/deployment
cd ~/tmp/dspm/deployment

# Create Terraform configuration
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
  regions                   = ["$DSPM_REGION"]
  scanning_subscription_id  = "/subscriptions/$SCANNING_SUBSCRIPTION_ID"
}
EOF

echo "Deploying Lacework DSPM:"
echo "  Subscription: $SCANNING_SUBSCRIPTION_ID"
echo "  Region:       $DSPM_REGION"
echo "  Integration:  $INTEGRATION_NAME"
echo ""

terraform init
terraform plan
terraform apply -auto-approve

echo ""
echo "Lacework DSPM deployment completed."
