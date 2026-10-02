#!/usr/bin/env bash

# ============================================================
# FortiCNAPP Azure Integration Preflight
#
# Usage:
#   ./forticnapp-preflight.sh <APP-ID> [SUBSCRIPTION-ID]
#
# Example:
#   ./forticnapp-preflight.sh 12345678-aaaa-bbbb-cccc-123456789abc
#
# Read-only:
#   This script does NOT create, modify, assign, or delete
#   Azure / Entra resources or permissions.
#
# Output:
#   preflight.json
# ============================================================

set -o pipefail

# ============================================================
# Colours
# ============================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ============================================================
# Counters / arrays
# ============================================================

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

REQUIRED_MISSING=()

REPORT_FILE="preflight.json"

# ============================================================
# Helper functions
# ============================================================

ok() {
    echo -e "  ${GREEN}✔ OK${RESET} $1"
    ((PASS_COUNT++))
}

fail() {
    echo -e "  ${RED}✘ FAIL${RESET} $1"
    ((FAIL_COUNT++))
}

warn() {
    echo -e "  ${YELLOW}⚠ WARN${RESET} $1"
    ((WARN_COUNT++))
}

info() {
    echo -e "  ${CYAN}ℹ INFO${RESET} $1"
}

missing() {
    REQUIRED_MISSING+=("$1")
}

# ============================================================
# Arguments
# ============================================================

if [[ -z "$1" ]]; then
    echo
    echo "Usage:"
    echo "  $0 <APP-ID> [SUBSCRIPTION-ID]"
    echo
    exit 1
fi

APP_ID="$1"

# ============================================================
# [1] Azure CLI / jq / authentication
# ============================================================

echo
echo "[1] Azure CLI / Authentication"
echo "------------------------------------------------------------"

if ! command -v az >/dev/null 2>&1; then
    fail "Azure CLI is not installed."
    exit 1
else
    ok "Azure CLI installed"
fi

if ! command -v jq >/dev/null 2>&1; then
    fail "jq is not installed."
    exit 1
else
    ok "jq installed"
fi

ACCOUNT_JSON=$(az account show -o json 2>/dev/null)

if [[ -z "$ACCOUNT_JSON" ]]; then
    fail "Not authenticated to Azure CLI."
    echo
    echo "Run:"
    echo "  az login"
    exit 1
else
    ok "Azure CLI authenticated"
fi

TENANT_ID=$(echo "$ACCOUNT_JSON" | jq -r '.tenantId // empty')
CURRENT_SUBSCRIPTION_ID=$(echo "$ACCOUNT_JSON" | jq -r '.id // empty')
CURRENT_SUBSCRIPTION_NAME=$(echo "$ACCOUNT_JSON" | jq -r '.name // empty')
AZURE_USER_NAME=$(echo "$ACCOUNT_JSON" | jq -r '.user.name // empty')

SUBSCRIPTION_ID="${2:-$CURRENT_SUBSCRIPTION_ID}"

echo "      Tenant       : $TENANT_ID"
echo "      Subscription : $SUBSCRIPTION_ID"

if [[ -n "$CURRENT_SUBSCRIPTION_NAME" ]]; then
    echo "      Name         : $CURRENT_SUBSCRIPTION_NAME"
fi

# ============================================================
# [2] Resolve signed-in Entra ID User
# ============================================================

echo
echo "[2] Entra ID User"
echo "------------------------------------------------------------"

USER_OBJECT_ID=""
USER_DISPLAY_NAME=""
USER_UPN=""

if [[ -z "$AZURE_USER_NAME" ]]; then

    fail "Could not determine the signed-in Azure account."
    missing "Entra ID User → Signed-in Azure account"

else

    echo "      Azure identity : $AZURE_USER_NAME"

    # --------------------------------------------------------
    # Resolve user through Microsoft Graph
    # --------------------------------------------------------

    USER_URL="https://graph.microsoft.com/v1.0/users/$(printf '%s' "$AZURE_USER_NAME" | jq -sRr @uri)"

    USER_RESPONSE=$(az rest \
        --method GET \
        --url "$USER_URL" \
        2>&1)

    USER_RC=$?

    if [[ $USER_RC -ne 0 ]]; then

        fail "Could not resolve the signed-in Entra ID User."

        echo
        echo -e "      ${RED}${BOLD}Microsoft Graph query failed.${RESET}"
        echo "      Identity: $AZURE_USER_NAME"
        echo
        echo "      This can indicate that the signed-in identity"
        echo "      cannot query Microsoft Graph users."

        missing "Entra ID User → Could not resolve user"

    else

        USER_OBJECT_ID=$(echo "$USER_RESPONSE" | jq -r '.id // empty')
        USER_DISPLAY_NAME=$(echo "$USER_RESPONSE" | jq -r '.displayName // empty')
        USER_UPN=$(echo "$USER_RESPONSE" | jq -r '.userPrincipalName // empty')

        if [[ -n "$USER_OBJECT_ID" ]]; then

            ok "Entra ID User resolved"

            echo "      Display Name : $USER_DISPLAY_NAME"
            echo "      UPN          : $USER_UPN"
            echo "      Object ID    : $USER_OBJECT_ID"

        else

            fail "Microsoft Graph returned no Entra user object."
            missing "Entra ID User → Could not resolve user"

        fi
    fi
fi

# ============================================================
# Function: check Entra role
# ============================================================

check_entra_role() {

    local ROLE_NAME="$1"
    local LABEL="$2"

    echo
    echo "$LABEL"
    echo "------------------------------------------------------------"

    if [[ -z "$USER_OBJECT_ID" ]]; then

        fail "Cannot verify ${ROLE_NAME}; Entra ID User was not resolved."
        missing "Entra ID User → ${ROLE_NAME}"
        return

    fi

    # --------------------------------------------------------
    # Get role definition
    # --------------------------------------------------------

    ROLE_DEFINITION_URL="https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=displayName%20eq%20'$(printf '%s' "$ROLE_NAME" | sed 's/ /%20/g')'"

    ROLE_RESPONSE=$(az rest \
        --method GET \
        --url "$ROLE_DEFINITION_URL" \
        2>&1)

    ROLE_RC=$?

    if [[ $ROLE_RC -ne 0 ]]; then

        fail "Could not verify ${ROLE_NAME}."
        echo -e "      ${RED}${BOLD}Microsoft Graph role query failed.${RESET}"
        echo "      This is a query/permission problem, not proof"
        echo "      that the role is missing."

        missing "Entra ID User → ${ROLE_NAME} → Unable to verify"

        return
    fi

    ROLE_ID=$(echo "$ROLE_RESPONSE" | jq -r '.value[0].id // empty')

    if [[ -z "$ROLE_ID" ]]; then

        fail "Could not find the ${ROLE_NAME} role definition."
        missing "Entra ID User → ${ROLE_NAME}"

        return
    fi

    # --------------------------------------------------------
    # Check active role assignment
    # --------------------------------------------------------

    ASSIGNMENT_URL="https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$USER_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$ROLE_ID'"

    ASSIGNMENT_RESPONSE=$(az rest \
        --method GET \
        --url "$ASSIGNMENT_URL" \
        2>&1)

    ASSIGNMENT_RC=$?

    if [[ $ASSIGNMENT_RC -ne 0 ]]; then

        fail "Could not verify ${ROLE_NAME}."
        echo -e "      ${RED}${BOLD}Microsoft Graph role-assignment query failed.${RESET}"
        echo "      This is not proof that the role is missing."

        missing "Entra ID User → ${ROLE_NAME} → Unable to verify"

        return
    fi

    ASSIGNMENT_COUNT=$(echo "$ASSIGNMENT_RESPONSE" | jq '.value | length')

    if [[ "$ASSIGNMENT_COUNT" -gt 0 ]]; then

        ok "${ROLE_NAME} assigned"

    else

        # ----------------------------------------------------
        # Check PIM eligible assignment
        # ----------------------------------------------------

        ELIGIBILITY_URL="https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?\$filter=principalId%20eq%20'$USER_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$ROLE_ID'"

        ELIGIBILITY_RESPONSE=$(az rest \
            --method GET \
            --url "$ELIGIBILITY_URL" \
            2>&1)

        ELIGIBILITY_RC=$?

        if [[ $ELIGIBILITY_RC -eq 0 ]]; then

            ELIGIBLE_COUNT=$(echo "$ELIGIBILITY_RESPONSE" | jq '.value | length')

            if [[ "$ELIGIBLE_COUNT" -gt 0 ]]; then

                warn "${ROLE_NAME} is PIM eligible but not currently active."
                echo -e "      ${YELLOW}${BOLD}ACTION REQUIRED:${RESET} Activate the role in PIM before running Automated Configuration."

                missing "Entra ID User → ${ROLE_NAME} → PIM role must be active"

            else

                fail "${ROLE_NAME} is not assigned."
                missing "Entra ID User → ${ROLE_NAME}"

            fi

        else

            fail "${ROLE_NAME} is not actively assigned."
            echo "      PIM eligibility could not be checked."
            missing "Entra ID User → ${ROLE_NAME}"

        fi
    fi
}

# ============================================================
# [3] Entra ID User - Application Administrator
# ============================================================

check_entra_role \
    "Application Administrator" \
    "[3] Entra ID User - Application Administrator"

# ============================================================
# [4] Entra ID User - Privileged Role Administrator
# ============================================================

check_entra_role \
    "Privileged Role Administrator" \
    "[4] Entra ID User - Privileged Role Administrator"

# ============================================================
# [5] Entra ID User - Azure Owner
# ============================================================

echo
echo "[5] Entra ID User - Azure Owner"
echo "------------------------------------------------------------"

USER_OWNER_FOUND="false"

if [[ -n "$USER_OBJECT_ID" ]]; then

    USER_OWNER_COUNT=$(az role assignment list \
        --assignee-object-id "$USER_OBJECT_ID" \
        --scope "/subscriptions/$SUBSCRIPTION_ID" \
        --role Owner \
        --include-inherited \
        --all \
        --query "length(@)" \
        -o tsv 2>/dev/null)

    if [[ "$USER_OWNER_COUNT" =~ ^[0-9]+$ ]] && [[ "$USER_OWNER_COUNT" -gt 0 ]]; then

        USER_OWNER_FOUND="true"
        ok "Entra ID User has Azure Owner on subscription"

    else

        warn "Azure Owner was not directly/inherited verified for the Entra ID User."
        echo "      This does not necessarily mean the user cannot perform"
        echo "      the required operation; PIM/delegated permissions may apply."

    fi

else

    warn "Cannot check Azure Owner because Entra ID User was not resolved."

fi

# ============================================================
# [6] FortiCNAPP App Registration
# ============================================================

echo
echo "[6] FortiCNAPP App Registration"
echo "------------------------------------------------------------"

APP_RESPONSE=$(az ad app show --id "$APP_ID" -o json 2>/dev/null)
APP_RC=$?

APP_OBJECT_ID=""
APP_DISPLAY_NAME=""

if [[ $APP_RC -ne 0 ]]; then

    fail "FortiCNAPP App Registration not found."
    missing "FortiCNAPP App Registration → $APP_ID"

else

    APP_OBJECT_ID=$(echo "$APP_RESPONSE" | jq -r '.id // empty')
    APP_DISPLAY_NAME=$(echo "$APP_RESPONSE" | jq -r '.displayName // empty')

    ok "FortiCNAPP App Registration exists"

    echo "      Display Name : $APP_DISPLAY_NAME"
    echo "      Client ID    : $APP_ID"
    echo "      Object ID    : $APP_OBJECT_ID"

fi

# ============================================================
# [7] FortiCNAPP Service Principal
# ============================================================

echo
echo "[7] FortiCNAPP Service Principal"
echo "------------------------------------------------------------"

SP_RESPONSE=$(az ad sp show --id "$APP_ID" -o json 2>/dev/null)
SP_RC=$?

SP_OBJECT_ID=""
SP_DISPLAY_NAME=""

if [[ $SP_RC -ne 0 ]]; then

    fail "FortiCNAPP Service Principal not found."
    missing "FortiCNAPP Service Principal → $APP_ID"

else

    SP_OBJECT_ID=$(echo "$SP_RESPONSE" | jq -r '.id // empty')
    SP_DISPLAY_NAME=$(echo "$SP_RESPONSE" | jq -r '.displayName // empty')

    ok "FortiCNAPP Service Principal exists"

    echo "      Display Name : $SP_DISPLAY_NAME"
    echo "      Object ID    : $SP_OBJECT_ID"

fi

# ============================================================
# [8] Service Principal - Azure Owner
# ============================================================

echo
echo "[8] FortiCNAPP Service Principal - Azure Owner"
echo "------------------------------------------------------------"

SP_OWNER_FOUND="false"

if [[ -n "$SP_OBJECT_ID" ]]; then

    SP_OWNER_COUNT=$(az role assignment list \
        --assignee-object-id "$SP_OBJECT_ID" \
        --scope "/subscriptions/$SUBSCRIPTION_ID" \
        --role Owner \
        --include-inherited \
        --all \
        --query "length(@)" \
        -o tsv 2>/dev/null)

    if [[ "$SP_OWNER_COUNT" =~ ^[0-9]+$ ]] && [[ "$SP_OWNER_COUNT" -gt 0 ]]; then

        SP_OWNER_FOUND="true"
        ok "Service Principal has Azure Owner on subscription"

    else

        fail "Service Principal does not have Azure Owner on subscription."
        echo -e "      ${RED}${BOLD}REQUIRED / MISSING:${RESET}"
        echo -e "      ${RED}${BOLD}FortiCNAPP Service Principal → Azure Owner${RESET}"

        missing "FortiCNAPP Service Principal → Azure Owner"

    fi

else

    fail "Cannot check Azure Owner because Service Principal was not resolved."
    missing "FortiCNAPP Service Principal → Azure Owner"

fi

# ============================================================
# Function: check SP Entra role
# ============================================================

check_sp_entra_role() {

    local ROLE_NAME="$1"
    local LABEL="$2"

    echo
    echo "$LABEL"
    echo "------------------------------------------------------------"

    if [[ -z "$SP_OBJECT_ID" ]]; then

        fail "Cannot verify ${ROLE_NAME}; Service Principal was not resolved."
        missing "FortiCNAPP Service Principal → ${ROLE_NAME}"
        return

    fi

    ROLE_DEFINITION_URL="https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=displayName%20eq%20'$(printf '%s' "$ROLE_NAME" | sed 's/ /%20/g')'"

    ROLE_RESPONSE=$(az rest \
        --method GET \
        --url "$ROLE_DEFINITION_URL" \
        2>&1)

    ROLE_RC=$?

    if [[ $ROLE_RC -ne 0 ]]; then

        fail "Could not verify ${ROLE_NAME}."
        echo -e "      ${RED}${BOLD}Microsoft Graph role query failed.${RESET}"

        missing "FortiCNAPP Service Principal → ${ROLE_NAME} → Unable to verify"

        return
    fi

    ROLE_ID=$(echo "$ROLE_RESPONSE" | jq -r '.value[0].id // empty')

    if [[ -z "$ROLE_ID" ]]; then

        fail "Could not find the ${ROLE_NAME} role definition."
        missing "FortiCNAPP Service Principal → ${ROLE_NAME}"

        return
    fi

    ASSIGNMENT_URL="https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$SP_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$ROLE_ID'"

    ASSIGNMENT_RESPONSE=$(az rest \
        --method GET \
        --url "$ASSIGNMENT_URL" \
        2>&1)

    ASSIGNMENT_RC=$?

    if [[ $ASSIGNMENT_RC -ne 0 ]]; then

        fail "Could not verify ${ROLE_NAME}."
        echo -e "      ${RED}${BOLD}Microsoft Graph role-assignment query failed.${RESET}"

        missing "FortiCNAPP Service Principal → ${ROLE_NAME} → Unable to verify"

        return
    fi

    ASSIGNMENT_COUNT=$(echo "$ASSIGNMENT_RESPONSE" | jq '.value | length')

    if [[ "$ASSIGNMENT_COUNT" -gt 0 ]]; then

        ok "${ROLE_NAME} assigned to Service Principal"

    else

        fail "${ROLE_NAME} is not assigned to Service Principal."
        echo -e "      ${RED}${BOLD}REQUIRED / MISSING:${RESET}"
        echo -e "      ${RED}${BOLD}FortiCNAPP Service Principal → ${ROLE_NAME}${RESET}"

        missing "FortiCNAPP Service Principal → ${ROLE_NAME}"

    fi
}

# ============================================================
# [9] Service Principal - Application Administrator
# ============================================================

check_sp_entra_role \
    "Application Administrator" \
    "[9] FortiCNAPP Service Principal - Application Administrator"

# ============================================================
# [10] Service Principal - Privileged Role Administrator
# ============================================================

check_sp_entra_role \
    "Privileged Role Administrator" \
    "[10] FortiCNAPP Service Principal - Privileged Role Administrator"

# ============================================================
# [11] Optional Directory Readers
# ============================================================

echo
echo "[11] Optional - Directory Readers"
echo "------------------------------------------------------------"

DIRECTORY_READER_FOUND="false"

if [[ -n "$SP_OBJECT_ID" ]]; then

    DIRECTORY_READER_ROLE_RESPONSE=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=displayName%20eq%20'Directory%20Readers'" \
        2>/dev/null)

    DIRECTORY_READER_ROLE_ID=$(echo "$DIRECTORY_READER_ROLE_RESPONSE" | jq -r '.value[0].id // empty')

    if [[ -n "$DIRECTORY_READER_ROLE_ID" ]]; then

        DIRECTORY_READER_ASSIGNMENT=$(az rest \
            --method GET \
            --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$SP_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$DIRECTORY_READER_ROLE_ID'" \
            2>/dev/null)

        DIRECTORY_READER_COUNT=$(echo "$DIRECTORY_READER_ASSIGNMENT" | jq '.value | length' 2>/dev/null)

        if [[ "$DIRECTORY_READER_COUNT" -gt 0 ]]; then

            DIRECTORY_READER_FOUND="true"
            ok "Directory Readers assigned"

        else

            warn "Directory Readers not assigned."
            echo "      Optional unless Entra ID user/group/member/app"
            echo "      registration collection is required."

        fi

    else

        warn "Could not verify optional Directory Readers role."

    fi

else

    warn "Cannot check Directory Readers because Service Principal was not resolved."

fi

# ============================================================
# [12] REQUIRED / MISSING
# ============================================================

echo
echo "[12] REQUIRED / MISSING"
echo "------------------------------------------------------------"

if [[ ${#REQUIRED_MISSING[@]} -eq 0 ]]; then

    echo -e "  ${GREEN}${BOLD}✔ No required prerequisites are currently missing.${RESET}"

else

    for ITEM in "${REQUIRED_MISSING[@]}"; do
        echo -e "  ${RED}${BOLD}✘ ${ITEM}${RESET}"
    done

fi

# ============================================================
# [13] Generate JSON report
# ============================================================

echo
echo "[13] Generate JSON Report"
echo "------------------------------------------------------------"

OVERALL_STATUS="PASS"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    OVERALL_STATUS="FAIL"
elif [[ "$WARN_COUNT" -gt 0 ]]; then
    OVERALL_STATUS="WARN"
fi

MISSING_JSON=$(printf '%s\n' "${REQUIRED_MISSING[@]}" | jq -R . | jq -s .)

if [[ -z "$MISSING_JSON" ]]; then
    MISSING_JSON="[]"
fi

jq -n \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg status "$OVERALL_STATUS" \
    --arg tenant_id "$TENANT_ID" \
    --arg subscription_id "$SUBSCRIPTION_ID" \
    --arg subscription_name "$CURRENT_SUBSCRIPTION_NAME" \
    --arg user "$USER_UPN" \
    --arg user_display_name "$USER_DISPLAY_NAME" \
    --arg user_object_id "$USER_OBJECT_ID" \
    --arg app_display_name "$APP_DISPLAY_NAME" \
    --arg app_client_id "$APP_ID" \
    --arg app_object_id "$APP_OBJECT_ID" \
    --arg sp_display_name "$SP_DISPLAY_NAME" \
    --arg sp_object_id "$SP_OBJECT_ID" \
    --argjson user_owner "$USER_OWNER_FOUND" \
    --argjson sp_owner "$SP_OWNER_FOUND" \
    --argjson directory_reader "$DIRECTORY_READER_FOUND" \
    --argjson successful_checks "$PASS_COUNT" \
    --argjson failed_checks "$FAIL_COUNT" \
    --argjson warnings "$WARN_COUNT" \
    --argjson required_missing "$MISSING_JSON" \
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
    display_name: $user_display_name,
    user_principal_name: $user,
    object_id: $user_object_id,

    required_roles: {
      application_administrator: "checked",
      privileged_role_administrator: "checked",
      azure_owner: $user_owner
    }
  },

  forticnapp_app_registration: {
    display_name: $app_display_name,
    client_id: $app_client_id,
    application_object_id: $app_object_id,

    service_principal: {
      display_name: $sp_display_name,
      object_id: $sp_object_id
    },

    required_permissions: {
      azure_owner: $sp_owner,
      application_administrator: "checked",
      privileged_role_administrator: "checked"
    },

    optional_permissions: {
      directory_readers: $directory_reader
    }
  },

  summary: {
    successful_checks: $successful_checks,
    failed_checks: $failed_checks,
    warnings: $warnings
  },

  required_missing: $required_missing
}
' > "$REPORT_FILE"

if [[ $? -eq 0 ]]; then
    ok "Generated $REPORT_FILE"
else
    fail "Could not generate $REPORT_FILE"
fi

# ============================================================
# [14] Final Summary
# ============================================================

echo
echo "============================================================"
echo " FortiCNAPP Azure Integration Preflight Summary"
echo "============================================================"

echo "  Successful checks : $PASS_COUNT"
echo "  Failed checks     : $FAIL_COUNT"
echo "  Warnings          : $WARN_COUNT"

echo

if [[ "$FAIL_COUNT" -eq 0 ]]; then

    if [[ "$WARN_COUNT" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✔ PRECHECK PASSED${RESET}"
    else
        echo -e "  ${YELLOW}${BOLD}⚠ PRECHECK PASSED WITH WARNINGS${RESET}"
    fi

else

    echo -e "  ${RED}${BOLD}✘ PRECHECK FAILED${RESET}"

fi

echo
echo "  JSON report: $REPORT_FILE"
echo
echo "  The report does not contain client secrets or credentials."
echo "============================================================"
