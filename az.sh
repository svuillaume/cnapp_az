#!/usr/bin/env bash

# ============================================================
# FortiCNAPP Azure Automated Configuration
# Entra ID User & App Registration Preflight Check
#
# Usage:
#   ./forticnapp-preflight.sh <APP-ID> [SUBSCRIPTION-ID]
#
# Output:
#   Console preflight results
#   ./preflight.json
#
# READ-ONLY:
#   This script does NOT modify Azure or Entra ID.
# ============================================================

set -u

APP_ID="${1:-}"
SUB_ID="${2:-}"

REPORT_FILE="preflight.json"

# ============================================================
# COLORS / STATUS
# ============================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

OK="${GREEN}✔ OK${RESET}"
FAIL="${RED}✘ FAIL${RESET}"
WARN="${YELLOW}⚠ WARN${RESET}"
INFO="${CYAN}ℹ INFO${RESET}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

REQUIRED_MISSING=()

# JSON values
USER_APP_ADMIN=false
USER_PRA=false
APP_OWNER=false
APP_APP_ADMIN=false
APP_PRA=false
APP_DIRECTORY_READER=false

# ============================================================
# FUNCTIONS
# ============================================================

pass() {
    echo -e "  ${OK} $1"
    ((PASS_COUNT++))
}

fail() {
    echo -e "  ${FAIL} $1"
    ((FAIL_COUNT++))
}

warn() {
    echo -e "  ${WARN} $1"
    ((WARN_COUNT++))
}

info() {
    echo -e "  ${INFO} $1"
}

add_missing() {
    REQUIRED_MISSING+=("$1")
}

section() {
    echo
    echo -e "${BOLD}[$1] $2${RESET}"
    echo "------------------------------------------------------------"
}

# ============================================================
# ARGUMENT CHECK
# ============================================================

if [[ -z "$APP_ID" ]]; then
    echo
    echo -e "${RED}${BOLD}ERROR: FortiCNAPP App Client ID is required.${RESET}"
    echo
    echo "Usage:"
    echo "  $0 <APP-ID> [SUBSCRIPTION-ID]"
    echo
    exit 1
fi

echo
echo "============================================================"
echo " FortiCNAPP Azure Automated Configuration"
echo " Entra ID User & App Registration Preflight"
echo "============================================================"

# ============================================================
# 1. AZURE CLI / LOGIN
# ============================================================

section "1" "Azure CLI / Login"

if ! command -v az >/dev/null 2>&1; then
    fail "Azure CLI is not installed."
    exit 1
else
    pass "Azure CLI is installed."
fi

if ! command -v jq >/dev/null 2>&1; then
    fail "jq is not installed."
    echo
    echo "Install jq or use Azure Cloud Shell."
    exit 1
else
    pass "jq is installed."
fi

ACCOUNT_JSON=$(az account show -o json 2>/dev/null)

if [[ -z "$ACCOUNT_JSON" ]]; then
    fail "No active Azure login."
    echo
    echo "Run:"
    echo "  az login"
    exit 1
else
    pass "Azure CLI is authenticated."
fi

TENANT_ID=$(echo "$ACCOUNT_JSON" | jq -r '.tenantId')
CURRENT_SUB_ID=$(echo "$ACCOUNT_JSON" | jq -r '.id')
SUB_NAME=$(echo "$ACCOUNT_JSON" | jq -r '.name')
USER_NAME=$(echo "$ACCOUNT_JSON" | jq -r '.user.name')

if [[ -z "$SUB_ID" ]]; then
    SUB_ID="$CURRENT_SUB_ID"
fi

echo
echo "  Entra Tenant      : $TENANT_ID"
echo "  Subscription ID   : $SUB_ID"
echo "  Subscription Name : $SUB_NAME"
echo "  Entra ID User     : $USER_NAME"

# ============================================================
# 2. ENTRA ID USER
# ============================================================

section "2" "Entra ID User"

USER_ID=$(az ad user show \
    --id "$USER_NAME" \
    --query id \
    -o tsv 2>/dev/null || true)

if [[ -z "$USER_ID" ]]; then
    fail "Could not resolve the signed-in Entra ID User."
    add_missing "Entra ID User could not be resolved"
else
    pass "Entra ID User found."
    echo "  User Object ID : $USER_ID"
fi

# ============================================================
# 3. ENTRA ID USER - APPLICATION ADMINISTRATOR
# ============================================================

section "3" "Entra ID User - Application Administrator"

APP_ADMIN_ROLE_ID=$(az rest \
    --method GET \
    --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=displayName%20eq%20'Application%20Administrator'" \
    --query "value[0].id" \
    -o tsv 2>/dev/null || true)

if [[ -n "$USER_ID" && -n "$APP_ADMIN_ROLE_ID" ]]; then

    USER_APP_ADMIN=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$USER_ID'%20and%20roleDefinitionId%20eq%20'$APP_ADMIN_ROLE_ID'" \
        --query "length(value)" \
        -o tsv 2>/dev/null || echo "0")

    if [[ "$USER_APP_ADMIN" -gt 0 ]]; then
        USER_APP_ADMIN=true
        pass "Application Administrator"
    else
        fail "Application Administrator"
        add_missing "Entra ID User → Application Administrator"
    fi

else
    fail "Could not verify Application Administrator"
    add_missing "Entra ID User → Application Administrator"
fi

# ============================================================
# 4. ENTRA ID USER - PRIVILEGED ROLE ADMINISTRATOR
# ============================================================

section "4" "Entra ID User - Privileged Role Administrator"

PRA_ROLE_ID=$(az rest \
    --method GET \
    --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=displayName%20eq%20'Privileged%20Role%20Administrator'" \
    --query "value[0].id" \
    -o tsv 2>/dev/null || true)

if [[ -n "$USER_ID" && -n "$PRA_ROLE_ID" ]]; then

    USER_PRA=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$USER_ID'%20and%20roleDefinitionId%20eq%20'$PRA_ROLE_ID'" \
        --query "length(value)" \
        -o tsv 2>/dev/null || echo "0")

    if [[ "$USER_PRA" -gt 0 ]]; then
        USER_PRA=true
        pass "Privileged Role Administrator"
    else
        fail "Privileged Role Administrator"
        add_missing "Entra ID User → Privileged Role Administrator"
    fi

else
    fail "Could not verify Privileged Role Administrator"
    add_missing "Entra ID User → Privileged Role Administrator"
fi

# ============================================================
# 5. ENTRA ID USER - AZURE OWNER
# ============================================================

section "5" "Entra ID User - Azure Subscription Permissions"

USER_OWNER_COUNT=$(az role assignment list \
    --assignee "$USER_NAME" \
    --scope "/subscriptions/$SUB_ID" \
    --include-inherited \
    --query "[?roleDefinitionName=='Owner'] | length(@)" \
    -o tsv 2>/dev/null || echo "0")

if [[ "$USER_OWNER_COUNT" -gt 0 ]]; then
    pass "Owner on target subscription"
else
    warn "Owner is not directly/inherited on the Entra ID User."
    info "Verify that the user can assign Azure RBAC roles."
fi

# ============================================================
# 6. FORTICNAPP APP REGISTRATION
# ============================================================

section "6" "FortiCNAPP App Registration"

APP_JSON=$(az ad app show \
    --id "$APP_ID" \
    -o json 2>/dev/null || true)

if [[ -z "$APP_JSON" ]]; then
    fail "App Registration NOT found."
    add_missing "FortiCNAPP App Registration"
    exit 1
fi

APP_OBJECT_ID=$(echo "$APP_JSON" | jq -r '.id')
APP_DISPLAY_NAME=$(echo "$APP_JSON" | jq -r '.displayName')

pass "App Registration found."

echo
echo "  Display Name : $APP_DISPLAY_NAME"
echo "  Client ID    : $APP_ID"
echo "  Object ID    : $APP_OBJECT_ID"

# ============================================================
# 7. SERVICE PRINCIPAL
# ============================================================

section "7" "FortiCNAPP Service Principal"

SP_JSON=$(az ad sp show \
    --id "$APP_ID" \
    -o json 2>/dev/null || true)

if [[ -z "$SP_JSON" ]]; then
    fail "Service Principal NOT found."
    add_missing "FortiCNAPP Service Principal"
    exit 1
fi

SP_OBJECT_ID=$(echo "$SP_JSON" | jq -r '.id')
SP_NAME=$(echo "$SP_JSON" | jq -r '.displayName')

pass "Service Principal found."

echo
echo "  Display Name : $SP_NAME"
echo "  Object ID    : $SP_OBJECT_ID"

# ============================================================
# 8. APP - AZURE OWNER
# ============================================================

section "8" "FortiCNAPP App - Azure Owner"

OWNER_COUNT=$(az role assignment list \
    --assignee-object-id "$SP_OBJECT_ID" \
    --scope "/subscriptions/$SUB_ID" \
    --include-inherited \
    --query "[?roleDefinitionName=='Owner'] | length(@)" \
    -o tsv 2>/dev/null || echo "0")

if [[ "$OWNER_COUNT" -gt 0 ]]; then
    APP_OWNER=true
    pass "Owner on target subscription"
else
    fail "Owner on target subscription"
    add_missing "FortiCNAPP App → Azure Owner on subscription"
fi

# ============================================================
# 9. APP - APPLICATION ADMINISTRATOR
# ============================================================

section "9" "FortiCNAPP App - Application Administrator"

if [[ -n "$APP_ADMIN_ROLE_ID" ]]; then

    APP_ADMIN_COUNT=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$SP_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$APP_ADMIN_ROLE_ID'" \
        --query "length(value)" \
        -o tsv 2>/dev/null || echo "0")

    if [[ "$APP_ADMIN_COUNT" -gt 0 ]]; then
        APP_APP_ADMIN=true
        pass "Application Administrator"
    else
        fail "Application Administrator"
        add_missing "FortiCNAPP App → Application Administrator"
    fi

else
    fail "Could not resolve Application Administrator role."
    add_missing "FortiCNAPP App → Application Administrator"
fi

# ============================================================
# 10. APP - PRIVILEGED ROLE ADMINISTRATOR
# ============================================================

section "10" "FortiCNAPP App - Privileged Role Administrator"

if [[ -n "$PRA_ROLE_ID" ]]; then

    PRA_COUNT=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$SP_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$PRA_ROLE_ID'" \
        --query "length(value)" \
        -o tsv 2>/dev/null || echo "0")

    if [[ "$PRA_COUNT" -gt 0 ]]; then
        APP_PRA=true
        pass "Privileged Role Administrator"
    else
        fail "Privileged Role Administrator"
        add_missing "FortiCNAPP App → Privileged Role Administrator"
    fi

else
    fail "Could not resolve Privileged Role Administrator role."
    add_missing "FortiCNAPP App → Privileged Role Administrator"
fi

# ============================================================
# 11. DIRECTORY READER - OPTIONAL
# ============================================================

section "11" "FortiCNAPP App - Directory Reader (Optional)"

DR_ROLE_ID=$(az rest \
    --method GET \
    --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=displayName%20eq%20'Directory%20Readers'" \
    --query "value[0].id" \
    -o tsv 2>/dev/null || true)

if [[ -n "$DR_ROLE_ID" ]]; then

    DR_COUNT=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$SP_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$DR_ROLE_ID'" \
        --query "length(value)" \
        -o tsv 2>/dev/null || echo "0")

    if [[ "$DR_COUNT" -gt 0 ]]; then
        APP_DIRECTORY_READER=true
        pass "Directory Reader"
        info "Entra user/group/app discovery is enabled."
    else
        info "Directory Reader not assigned."
        info "Optional - required only for Entra directory data collection."
    fi

else
    warn "Could not resolve Directory Reader role."
fi

# ============================================================
# 12. REQUIRED / MISSING
# ============================================================

echo
echo "============================================================"
echo -e "${RED}${BOLD} REQUIRED / MISSING${RESET}"
echo "============================================================"

if [[ ${#REQUIRED_MISSING[@]} -eq 0 ]]; then

    echo
    echo -e "${GREEN}${BOLD}✔ NONE${RESET}"
    echo
    echo -e "${GREEN}${BOLD}All required FortiCNAPP prerequisites are present.${RESET}"

else

    echo

    for item in "${REQUIRED_MISSING[@]}"; do
        echo -e "  ${RED}${BOLD}✘ $item${RESET}"
    done

fi

# ============================================================
# 13. GENERATE JSON REPORT
# ============================================================

TIMESTAMP=$(date --iso-8601=seconds 2>/dev/null || date)

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    OVERALL_STATUS="PASSED"
else
    OVERALL_STATUS="FAILED"
fi

# Build missing JSON array safely
MISSING_JSON="[]"

if [[ ${#REQUIRED_MISSING[@]} -gt 0 ]]; then
    MISSING_JSON=$(printf '%s\n' "${REQUIRED_MISSING[@]}" | jq -R . | jq -s .)
fi

jq -n \
    --arg timestamp "$TIMESTAMP" \
    --arg status "$OVERALL_STATUS" \
    --arg tenant_id "$TENANT_ID" \
    --arg subscription_id "$SUB_ID" \
    --arg subscription_name "$SUB_NAME" \
    --arg user "$USER_NAME" \
    --arg user_object_id "${USER_ID:-}" \
    --arg app_display_name "$APP_DISPLAY_NAME" \
    --arg client_id "$APP_ID" \
    --arg app_object_id "$APP_OBJECT_ID" \
    --arg sp_object_id "$SP_OBJECT_ID" \
    --arg sp_name "$SP_NAME" \
    --argjson user_application_administrator "$USER_APP_ADMIN" \
    --argjson user_privileged_role_administrator "$USER_PRA" \
    --argjson app_azure_owner "$APP_OWNER" \
    --argjson app_application_administrator "$APP_APP_ADMIN" \
    --argjson app_privileged_role_administrator "$APP_PRA" \
    --argjson app_directory_reader "$APP_DIRECTORY_READER" \
    --argjson successful_checks "$PASS_COUNT" \
    --argjson failed_checks "$FAIL_COUNT" \
    --argjson warnings "$WARN_COUNT" \
    --argjson missing "$MISSING_JSON" \
'
{
  timestamp: $timestamp,
  status: $status,

  azure: {
    tenant_id: $tenant_id,
    subscription_id: $subscription_id,
    subscription_name: $subscription_name
  },

  entra_id_user: {
    user: $user,
    object_id: $user_object_id,

    required_roles: {
      application_administrator: $user_application_administrator,
      privileged_role_administrator: $user_privileged_role_administrator
    }
  },

  forticnapp_app_registration: {
    display_name: $app_display_name,
    client_id: $client_id,
    application_object_id: $app_object_id,

    service_principal: {
      name: $sp_name,
      object_id: $sp_object_id
    },

    required_permissions: {
      azure_owner: $app_azure_owner,
      application_administrator: $app_application_administrator,
      privileged_role_administrator: $app_privileged_role_administrator
    },

    optional_permissions: {
      directory_reader: $app_directory_reader
    }
  },

  summary: {
    successful_checks: $successful_checks,
    failed_checks: $failed_checks,
    warnings: $warnings
  },

  required_missing: $missing
}
' > "$REPORT_FILE"

# ============================================================
# 14. FINAL SUMMARY
# ============================================================

echo
echo "============================================================"
echo " PRE-FLIGHT SUMMARY"
echo "============================================================"

echo
echo -e "  ${GREEN}✔ Successful checks : $PASS_COUNT${RESET}"
echo -e "  ${RED}✘ Failed checks     : $FAIL_COUNT${RESET}"
echo -e "  ${YELLOW}⚠ Warnings          : $WARN_COUNT${RESET}"

echo
echo "------------------------------------------------------------"
echo " Entra ID User"
echo "------------------------------------------------------------"
echo "  $USER_NAME"

echo
echo "  Required:"
echo "    Application Administrator"
echo "    Privileged Role Administrator"

echo
echo "------------------------------------------------------------"
echo " FortiCNAPP App Registration / Service Principal"
echo "------------------------------------------------------------"
echo "  Name      : $APP_DISPLAY_NAME"
echo "  Client ID : $APP_ID"
echo "  SP Object : $SP_OBJECT_ID"

echo
echo "  Required:"
echo "    Azure Owner"
echo "    Application Administrator"
echo "    Privileged Role Administrator"

echo
echo "------------------------------------------------------------"
echo " JSON REPORT"
echo "------------------------------------------------------------"

if [[ -f "$REPORT_FILE" ]]; then
    echo -e "  ${GREEN}✔ Generated:${RESET} $REPORT_FILE"
else
    echo -e "  ${RED}✘ Failed to generate:${RESET} $REPORT_FILE"
fi

echo
echo "============================================================"

if [[ "$FAIL_COUNT" -eq 0 ]]; then

    echo
    echo -e "${GREEN}${BOLD}✔ PRE-FLIGHT PASSED${RESET}"
    echo -e "${GREEN}All required FortiCNAPP prerequisites are present.${RESET}"

else

    echo
    echo -e "${RED}${BOLD}✘ PRE-FLIGHT FAILED${RESET}"
    echo -e "${RED}Review the REQUIRED / MISSING section above.${RESET}"

fi

echo
echo "============================================================"
echo
