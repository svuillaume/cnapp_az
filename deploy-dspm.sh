#!/usr/bin/env bash
# Interactively asks for the DSPM inputs, writes ~/.lacework.toml (profile "forticnapp"),
# main.tf and version.tf, then runs terraform init / apply.
#
# Lacework provider auth: the provider reads ~/.lacework.toml. This script
#   1. MERGES the [forticnapp] profile into ~/.lacework.toml (other profiles are preserved)
#   2. verifies the credentials against the FortiCNAPP API BEFORE running terraform
#   3. pins   provider "lacework" { profile = "forticnapp" }   in main.tf, so a later manual
#      `terraform plan/apply` in a fresh shell works without LW_PROFILE being exported.
#
# Optional: SKIP_AUTH_CHECK=1 skips the API credential test.
set -euo pipefail

LW_PROFILE_NAME="forticnapp"

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
  # Accept 'acct', 'acct.lacework.net' or 'https://acct.lacework.net/' -> 'acct'
  LW_ACCOUNT_IN="${LW_ACCOUNT_IN#http://}"
  LW_ACCOUNT_IN="${LW_ACCOUNT_IN#https://}"
  LW_ACCOUNT_IN="${LW_ACCOUNT_IN%%/*}"
  LW_ACCOUNT_IN="${LW_ACCOUNT_IN%.lacework.net}"
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

# --- Verify the credentials work BEFORE touching anything ---
if [[ "${SKIP_AUTH_CHECK:-0}" != "1" ]]; then
  echo "Testing FortiCNAPP API credentials against https://${LW_ACCOUNT_IN}.lacework.net ..."
  # Secret goes in via stdin (-H @-), so it never appears in the process list
  HTTP_CODE="$(printf 'X-LW-UAKS: %s\n' "$LW_SECRET_IN" | curl -s -o /dev/null --max-time 20 \
      -w '%{http_code}' -X POST "https://${LW_ACCOUNT_IN}.lacework.net/api/v2/access/tokens" \
      -H @- -H 'Content-Type: application/json' \
      -d '{"keyId":"'"${LW_KEY_IN}"'","expiryTime":3600}' 2>/dev/null || true)"
  case "$HTTP_CODE" in
    200|201) echo "✓ FortiCNAPP credentials accepted (HTTP $HTTP_CODE)" ;;
    401|403) echo "✗ FortiCNAPP rejected the API key/secret (HTTP $HTTP_CODE). Nothing was written." >&2
             echo "  Check the key, the secret, and that the key is enabled." >&2
             exit 1 ;;
    404|000|"") echo "✗ Could not reach https://${LW_ACCOUNT_IN}.lacework.net (HTTP ${HTTP_CODE:-none})." >&2
             echo "  Check the account name (just '<account>', no .lacework.net) and your network/proxy." >&2
             exit 1 ;;
    *)       echo "⚠ Unexpected HTTP $HTTP_CODE from the FortiCNAPP API - continuing, but check the account name." ;;
  esac
fi

# --- Merge the profile into ~/.lacework.toml (preserve any other profiles) ---
LW_TOML="$HOME/.lacework.toml"
LW_TMP="$(umask 077; mktemp "${LW_TOML}.XXXXXX")"
if [[ -f "$LW_TOML" ]]; then
  cp -p "$LW_TOML" "$LW_TOML.bak.$(date +%Y%m%d%H%M%S)"
  echo "Existing $LW_TOML backed up."
  # keep every section EXCEPT [forticnapp]
  awk -v p="$LW_PROFILE_NAME" '
    /^[[:space:]]*\[/ { h = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*(#.*)?$/, "", h); skip = (h == p) }
    !skip { print }
  ' "$LW_TOML" > "$LW_TMP"
  [[ -s "$LW_TMP" ]] && echo >> "$LW_TMP"
fi
cat >> "$LW_TMP" <<EOF
[${LW_PROFILE_NAME}]
  account = "${LW_ACCOUNT_IN}"
  api_key = "${LW_KEY_IN}"
  api_secret = "${LW_SECRET_IN}"
  version = 2
EOF
chmod 600 "$LW_TMP"
mv "$LW_TMP" "$LW_TOML"
echo "Written: $LW_TOML (profile: ${LW_PROFILE_NAME}; other profiles preserved)"
# Belt and braces: also select the profile through the environment for this run
export LW_PROFILE="$LW_PROFILE_NAME"

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

# Pinned to the [${LW_PROFILE_NAME}] profile in ~/.lacework.toml, so this works in any shell
# (no need to export LW_PROFILE before running terraform manually).
provider "lacework" {
  profile = "${LW_PROFILE_NAME}"
}

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
# (no \${CONFIRM,,}: that needs bash 4 and fails on macOS's default bash 3.2)
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "== terraform apply =="
  terraform apply -auto-approve
else
  echo "Not applied. Run later with: terraform apply"
fi
