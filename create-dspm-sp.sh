#!/bin/bash

set -e

# Configuration
SCANNING_SUBSCRIPTION_ID="<your-scanning-subscription-id>"
SERVICE_PRINCIPAL_NAME="lacework-dspm"

# Create working directory
mkdir -p ~/tmp/dspm
cd ~/tmp/dspm

# Clone repository if it doesn't already exist
if [ ! -d "terraform-azure-dspm" ]; then
    git clone https://github.com/lacework/terraform-azure-dspm.git
fi

# Copy example Terraform configuration
cp terraform-azure-dspm/service-principal/example/main.tf .

# Update configuration
sed -i.bak \
    -e "s/<your-scanning-subscription-id>/$SCANNING_SUBSCRIPTION_ID/g" \
    -e "s/<your-service-principal-name>/$SERVICE_PRINCIPAL_NAME/g" \
    main.tf

# Initialize Terraform
terraform init

# Create the Service Principal
terraform apply \
    -var="scanning_subscription_id=$SCANNING_SUBSCRIPTION_ID" \
    -var="service_principal_name=$SERVICE_PRINCIPAL_NAME"

# Export credentials
export ARM_CLIENT_ID=$(terraform output -raw example_service_principal_client_id)
export ARM_CLIENT_SECRET=$(terraform output -raw example_service_principal_client_secret)
export ARM_TENANT_ID=$(terraform output -raw example_service_principal_tenant_id)
export ARM_SUBSCRIPTION_ID="$SCANNING_SUBSCRIPTION_ID"

echo ""
echo "Service Principal created."
echo "ARM_CLIENT_ID=$ARM_CLIENT_ID"
echo "ARM_TENANT_ID=$ARM_TENANT_ID"
echo "ARM_SUBSCRIPTION_ID=$ARM_SUBSCRIPTION_ID"
echo "ARM_CLIENT_SECRET=<hidden>"
