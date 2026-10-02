#single region Subscritpion Level
#
#!/usr/bin/env bash

set -e

echo
echo "=============================================="
echo " FortiCNAPP Azure Agentless Integration"
echo "=============================================="
echo

# ------------------------------------------------
# Collect information
# ------------------------------------------------

read -rp "FortiCNAPP account: " LW_ACCOUNT
read -rp "FortiCNAPP API key: " LW_API_KEY
read -rsp "FortiCNAPP API secret: " LW_API_SECRET
echo

read -rp "Azure Tenant ID: " AZ_TENANT_ID
read -rp "Azure Subscription ID: " AZ_SUBSCRIPTION_ID
read -rp "Azure region [canadacentral]: " AZ_REGION
AZ_REGION=${AZ_REGION:-canadacentral}

read -rp "Scanning Resource Group [FFHAZCRGFORTICNAPP]: " RG_NAME
RG_NAME=${RG_NAME:-FFHAZCRGFORTICNAPP}

read -rp "FortiCNAPP integration name [az_forticnapp_agentless]: " INTEGRATION_NAME
INTEGRATION_NAME=${INTEGRATION_NAME:-az_forticnapp_agentless}

echo
echo "----------------------------------------------"
echo "Configuration"
echo "----------------------------------------------"
echo "Tenant:          $AZ_TENANT_ID"
echo "Subscription:    $AZ_SUBSCRIPTION_ID"
echo "Region:          $AZ_REGION"
echo "Resource Group:  $RG_NAME"
echo "Integration:     $INTEGRATION_NAME"
echo "----------------------------------------------"
echo

read -rp "Continue? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# ------------------------------------------------
# Create working directory
# ------------------------------------------------

WORKDIR="$HOME/tf_forticnapp_agentless"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo
echo "Working directory:"
pwd
echo

# ------------------------------------------------
# Check prerequisites
# ------------------------------------------------

echo "Checking prerequisites..."

command -v terraform >/dev/null 2>&1 || {
    echo "ERROR: terraform is not installed."
    exit 1
}

command -v az >/dev/null 2>&1 || {
    echo "ERROR: Azure CLI (az) is not installed."
    exit 1
}

echo "Terraform: OK"
echo "Azure CLI: OK"

# ------------------------------------------------
# Azure login
# ------------------------------------------------

echo
echo "Checking Azure login..."

if ! az account show >/dev/null 2>&1; then
    echo "Azure CLI is not logged in."
    az login
fi

echo
echo "Setting Azure subscription..."

az account set --subscription "$AZ_SUBSCRIPTION_ID"

echo
echo "Azure account:"
az account show \
    --query "{subscription:name, subscriptionId:id, tenantId:tenantId}" \
    -o table

# ------------------------------------------------
# Create version.tf
# ------------------------------------------------

echo
echo "Creating version.tf..."

cat > version.tf <<'TFEOF'
terraform {
  required_version = ">= 0.13"

  required_providers {
    lacework = {
      source  = "lacework/lacework"
      version = "~> 2.6"
    }
  }
}
TFEOF

# ------------------------------------------------
# Create az_agentless.tf
# ------------------------------------------------

echo "Creating az_agentless.tf..."

cat > az_agentless.tf <<TFEOF
provider "lacework" {
  profile = "forticnapp"
}

module "lacework_azure_agentless_scanning_subscription_canadacentral" {
  source = "lacework/agentless-scanning/azure"

  integration_level              = "SUBSCRIPTION"
  lacework_integration_name      = "$INTEGRATION_NAME"
  global                         = true
  create_log_analytics_workspace = true
  region                         = "$AZ_REGION"

  scanning_resource_group_name   = "$RG_NAME"
  tenant_id                      = "$AZ_TENANT_ID"

  included_subscriptions = [
    "/subscriptions/$AZ_SUBSCRIPTION_ID"
  ]
}
TFEOF

# ------------------------------------------------
# Create .lacework.toml
# ------------------------------------------------

echo "Creating .lacework.toml..."

cat > .lacework.toml <<TOMLEOF
[forticnapp]
  account = "$LW_ACCOUNT"
  api_key = "$LW_API_KEY"
  api_secret = "$LW_API_SECRET"
  version = 2
TOMLEOF

chmod 600 .lacework.toml

# ------------------------------------------------
# Initialize Terraform
# ------------------------------------------------

echo
echo "=============================================="
echo " Terraform Init"
echo "=============================================="

terraform init

# ------------------------------------------------
# Format
# ------------------------------------------------

echo
echo "=============================================="
echo " Terraform Format"
echo "=============================================="

terraform fmt

# ------------------------------------------------
# Validate
# ------------------------------------------------

echo
echo "=============================================="
echo " Terraform Validate"
echo "=============================================="

terraform validate

# ------------------------------------------------
# Plan
# ------------------------------------------------

echo
echo "=============================================="
echo " Terraform Plan"
echo "=============================================="

terraform plan

# ------------------------------------------------
# Apply
# ------------------------------------------------

echo
echo "=============================================="
echo " Ready to deploy"
echo "=============================================="
echo
echo "Terraform plan completed successfully."
echo

read -rp "Apply the FortiCNAPP Agentless integration? [y/N]: " APPLY

if [[ ! "$APPLY" =~ ^[Yy]$ ]]; then
    echo
    echo "Plan completed. Nothing was deployed."
    exit 0
fi

echo
echo "=============================================="
echo " Terraform Apply"
echo "=============================================="

terraform apply -auto-approve

echo
echo "=============================================="
echo " FortiCNAPP Agentless Integration Complete"
echo "=============================================="
echo
echo "Terraform state:"
terraform output 2>/dev/null || true

echo
echo "Working directory:"
pwd
echo
EOF
