#!/usr/bin/env bash
# Interactively asks for the three DSPM inputs and writes main.tf
set -euo pipefail

read -r -p "lacework_integration_name [azure-dspm]: " INTEGRATION_NAME
INTEGRATION_NAME="${INTEGRATION_NAME:-azure-dspm}"

read -r -p "regions (comma-separated) [East US]: " REGIONS_INPUT
REGIONS_INPUT="${REGIONS_INPUT:-East US}"

SUB_INPUT=""
while [[ -z "$SUB_INPUT" ]]; do
  read -r -p "scanning_subscription_id (GUID or /subscriptions/<GUID>): " SUB_INPUT
done
SUBSCRIPTION_ID="/subscriptions/${SUB_INPUT#/subscriptions/}"

# --- FortiCNAPP credentials -> ~/.lacework.toml (profile "forticnapp") ---
LW_ACCOUNT_IN=""
while [[ -z "$LW_ACCOUNT_IN" ]]; do
  read -r -p "FortiCNAPP account (<account> in <account>.lacework.net): " LW_ACCOUNT_IN
done
LW_KEY_IN=""
while [[ -z "$LW_KEY_IN" ]]; do
  read -r -p "FortiCNAPP api_key: " LW_KEY_IN
done
LW_SECRET_IN=""
while [[ -z "$LW_SECRET_IN" ]]; do
  read -r -s -p "FortiCNAPP api_secret (hidden): " LW_SECRET_IN
  echo
done

LW_TOML="$HOME/.lacework.toml"
if [[ -f "$LW_TOML" ]]; then
  cp -p "$LW_TOML" "$LW_TOML.bak.$(date +%Y%m%d%H%M%S)"
  echo "Existing $LW_TOML backed up."
fi
umask 077
cat > "$LW_TOML" <<EOF
[forticnapp]
  account = "${LW_ACCOUNT_IN}"
  api_key = "${LW_KEY_IN}"
  api_secret = "${LW_SECRET_IN}"
  version = 2
EOF
chmod 600 "$LW_TOML"
umask 022
echo "Written: $LW_TOML (profile: forticnapp)"
# Make the empty provider "lacework" {} use this profile
export LW_PROFILE=forticnapp

# "East US, West US 2" -> "East US", "West US 2"
REGIONS_HCL=""
IFS=',' read -ra REGION_ARR <<< "$REGIONS_INPUT"
for r in "${REGION_ARR[@]}"; do
  r="$(echo "$r" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$r" ]] && continue
  REGIONS_HCL+="${REGIONS_HCL:+, }\"${r}\""
done
[[ -z "$REGIONS_HCL" ]] && { echo "No valid region entered." >&2; exit 1; }

[[ -f main.tf ]] && cp main.tf "main.tf.bak.$(date +%Y%m%d%H%M%S)"

cat > main.tf <<EOF
provider "azurerm" {
  features {}
}

provider "lacework" {}

module "lacework_azure_dspm" {
  source  = "lacework/dspm/azure"
  version = "~> 0.1"

  # Name of the Lacework cloud account integration.
  lacework_integration_name = "${INTEGRATION_NAME}"
  # Regions to deploy scanners to.
  regions                   = [${REGIONS_HCL}]
  # Subscription ID to deploy DSPM within.
  scanning_subscription_id  = "${SUBSCRIPTION_ID}"
  # Scan interval in hours (allowed: 24, 72, 168, 720). The module's default is
  # null, which fails its own validation, so set it explicitly.
  scan_frequency_hours      = 24
}
EOF

[[ -f version.tf ]] && cp version.tf "version.tf.bak.$(date +%Y%m%d%H%M%S)"

cat > version.tf <<'EOF'
terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.80"
    }
    lacework = {
      source  = "lacework/lacework"
      version = "~> 2.3, != 2.4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}
EOF

echo
echo "Written: $(pwd)/main.tf"
echo "Written: $(pwd)/version.tf"
cat main.tf version.tf

command -v terraform >/dev/null 2>&1 || { echo "terraform not found in PATH." >&2; exit 1; }

echo
echo "== terraform init =="
terraform init

echo
read -r -p "Apply the configuration above now? [y/N]: " CONFIRM
if [[ "${CONFIRM,,}" == "y" ]]; then
  echo "== terraform apply =="
  terraform apply -auto-approve
else
  echo "Not applied. Run later with: terraform apply"
fi
