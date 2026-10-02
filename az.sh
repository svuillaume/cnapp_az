#!/usr/bin/env bash

# ============================================================
# FortiCNAPP Azure Integration Preflight
#
# Usage:
#   ./forticnapp-preflight.sh <APP-ID> [SUBSCRIPTION-ID]
#
# Example:
#   ./forticnapp-preflight.sh 6dced100-9c31-416f-aed1-67e8cfc9fe5f
#
# READ-ONLY - does not modify Azure or Entra ID
# ============================================================

set -o pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

REQUIRED_MISSING=()
REPORT_FILE="preflight.json"

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
    echo "Usage: $0 <APP-ID> [SUBSCRIPTION-ID]"
    exit 1
fi

APP_ID="$1"

# ============================================================
# [1] Azure CLI / Authentication
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
    exit 1
else
    ok "Azure CLI authenticated"
fi

TENANT_ID=$(echo "$ACCOUNT_JSON" | jq -r '.tenantId // empty')
SUBSCRIPTION_ID="${2:-$(echo "$ACCOUNT_JSON" | jq -r '.id // empty')}"
SUBSCRIPTION_NAME=$(echo "$ACCOUNT_JSON" | jq -r '.name // empty')
AZURE_USER_NAME=$(echo "$ACCOUNT_JSON" | jq -r '.user.name // empty')

echo "      Tenant       : $TENANT_ID"
echo "      Subscription : $SUBSCRIPTION_ID"
echo "      Azure user   : $AZURE_USER_NAME"

# ============================================================
# [2] Entra ID User
#
# IMPORTANT:
# Use Microsoft Graph /me.
# Do NOT use /users/<UPN>.
# ============================================================

echo
echo "[2] Entra ID User"
echo "------------------------------------------------------------"

USER_OBJECT_ID=""
USER_DISPLAY_NAME=""
USER_UPN=""

USER_RESPONSE=$(az rest \
    --method GET \
    --url "https://graph.microsoft.com/v1.0/me" \
    2>&1)

USER_RC=$?

if [[ $USER_RC -ne 0 ]]; then

    fail "Could not resolve the signed-in Entra ID User."
    echo
    echo -e "      ${RED}${BOLD}Microsoft Graph /me query failed.${RESET}"
    echo "      Azure identity: $AZURE_USER_NAME"
    echo
    echo "      Test manually with:"
    echo
    echo "      az rest --method GET \\"
    echo "        --url 'https://graph.microsoft.com/v1.0/me' \\"
    echo "        --query '{Name:displayName,UPN:userPrincipalName,ID:id}' \\"
    echo "        -o table"

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

        fail "Microsoft Graph /me returned no user object."
        missing "Entra ID User → Could not resolve user"

    fi
fi

# ============================================================
# Function: Check Entra role for USER
# ============================================================

check_user_role() {

    local ROLE_NAME="$1"
    local SECTION="$2"

    echo
    echo "$SECTION"
    echo "------------------------------------------------------------"

    if [[ -z "$USER_OBJECT_ID" ]]; then

        fail "Cannot verify ${ROLE_NAME}; Entra ID User was not resolved."
        missing "Entra ID User → ${ROLE_NAME}"
        return

    fi

    # --------------------------------------------------------
    # Get role definition ID
    # --------------------------------------------------------

    ROLE_RESPONSE=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=displayName%20eq%20'${ROLE_NAME// /%20}'" \
        2>&1)

    if [[ $? -ne 0 ]]; then

        fail "Could not query ${ROLE_NAME} role definition."
        missing "Entra ID User → ${ROLE_NAME} → Unable to query"

        return
    fi

    ROLE_ID=$(echo "$ROLE_RESPONSE" | jq -r '.value[0].id // empty')

    if [[ -z "$ROLE_ID" ]]; then

        fail "Could not find ${ROLE_NAME} role definition."
        missing "Entra ID User → ${ROLE_NAME}"

        return
    fi

    # --------------------------------------------------------
    # Check active assignment
    # --------------------------------------------------------

    ASSIGNMENT_RESPONSE=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$USER_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$ROLE_ID'" \
        2>&1)

    if [[ $? -ne 0 ]]; then

        fail "Could not verify ${ROLE_NAME}."
        echo -e "      ${RED}${BOLD}Microsoft Graph role-assignment query failed.${RESET}"
        missing "Entra ID User → ${ROLE_NAME} → Unable to query"

        return
    fi

    COUNT=$(echo "$ASSIGNMENT_RESPONSE" | jq '.value | length')

    if [[ "$COUNT" -gt 0 ]]; then

        ok "${ROLE_NAME} assigned"

    else

        # ----------------------------------------------------
        # Check PIM eligibility
        # ----------------------------------------------------

        ELIGIBILITY_RESPONSE=$(az rest \
            --method GET \
            --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?\$filter=principalId%20eq%20'$USER_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$ROLE_ID'" \
            2>/dev/null)

        ELIGIBLE_COUNT=$(echo "$ELIGIBILITY_RESPONSE" | jq '.value | length' 2>/dev/null)

        if [[ "$ELIGIBLE_COUNT" -gt 0 ]]; then

            warn "${ROLE_NAME} is PIM eligible but not currently active."
            echo -e "      ${YELLOW}${BOLD}ACTION REQUIRED:${RESET} Activate this role in PIM."

            missing "Entra ID User → ${ROLE_NAME} → Activate PIM role"

        else

            fail "${ROLE_NAME} is not assigned."
            echo -e "      ${RED}${BOLD}REQUIRED / MISSING:${RESET}"
            echo -e "      ${RED}${BOLD}Entra ID User → ${ROLE_NAME}${RESET}"

            missing "Entra ID User → ${ROLE_NAME}"

        fi
    fi
}

# ============================================================
# [3] Application Administrator
# ============================================================

check_user_role \
    "Application Administrator" \
    "[3] Entra ID User - Application Administrator"

# ============================================================
# [4] Privileged Role Administrator
# ============================================================

check_user_role \
    "Privileged Role Administrator" \
    "[4] Entra ID User - Privileged Role Administrator"

# ============================================================
# [5] Entra ID User - Azure Owner
# ============================================================

echo
echo "[5] Entra ID User - Azure Owner"
echo "------------------------------------------------------------"

USER_OWNER="false"

if [[ -n "$USER_OBJECT_ID" ]]; then

    OWNER_COUNT=$(az role assignment list \
        --assignee-object-id "$USER_OBJECT_ID" \
        --scope "/subscriptions/$SUBSCRIPTION_ID" \
        --role Owner \
        --include-inherited \
        --all \
        --query "length(@)" \
        -o tsv 2>/dev/null)

    if [[ "$OWNER_COUNT" =~ ^[0-9]+$ ]] && [[ "$OWNER_COUNT" -gt 0 ]]; then

        USER_OWNER="true"
        ok "Entra ID User has Azure Owner"

    else

        warn "Azure Owner not verified for Entra ID User."
        echo "      This can be affected by PIM or delegated Azure RBAC."

    fi

else

    warn "Cannot check Azure Owner because user was not resolved."

fi

# ============================================================
# [6] FortiCNAPP App Registration
#
# Use Microsoft Graph instead of az ad app show.
# ============================================================

echo
echo "[6] FortiCNAPP App Registration"
echo "------------------------------------------------------------"

APP_RESPONSE=$(az rest \
    --method GET \
    --url "https://graph.microsoft.com/v1.0/applications?\$filter=appId%20eq%20'$APP_ID'" \
    2>&1)

if [[ $? -ne 0 ]]; then

    fail "Could not query App Registration."
    echo -e "      ${RED}${BOLD}Microsoft Graph application query failed.${RESET}"
    missing "FortiCNAPP App Registration → $APP_ID"

else

    APP_OBJECT_ID=$(echo "$APP_RESPONSE" | jq -r '.value[0].id // empty')
    APP_DISPLAY_NAME=$(echo "$APP_RESPONSE" | jq -r '.value[0].displayName // empty')

    if [[ -n "$APP_OBJECT_ID" ]]; then

        ok "FortiCNAPP App Registration exists"

        echo "      Display Name : $APP_DISPLAY_NAME"
        echo "      Client ID    : $APP_ID"
        echo "      Object ID    : $APP_OBJECT_ID"

    else

        fail "FortiCNAPP App Registration not found."
        missing "FortiCNAPP App Registration → $APP_ID"

    fi
fi

# ============================================================
# [7] FortiCNAPP Service Principal
# ============================================================

echo
echo "[7] FortiCNAPP Service Principal"
echo "------------------------------------------------------------"

SP_RESPONSE=$(az rest \
    --method GET \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId%20eq%20'$APP_ID'" \
    2>&1)

SP_OBJECT_ID=""
SP_DISPLAY_NAME=""

if [[ $? -ne 0 ]]; then

    fail "Could not query Service Principal."
    missing "FortiCNAPP Service Principal → $APP_ID"

else

    SP_OBJECT_ID=$(echo "$SP_RESPONSE" | jq -r '.value[0].id // empty')
    SP_DISPLAY_NAME=$(echo "$SP_RESPONSE" | jq -r '.value[0].displayName // empty')

    if [[ -n "$SP_OBJECT_ID" ]]; then

        ok "FortiCNAPP Service Principal exists"

        echo "      Display Name : $SP_DISPLAY_NAME"
        echo "      Object ID    : $SP_OBJECT_ID"

    else

        fail "FortiCNAPP Service Principal not found."
        missing "FortiCNAPP Service Principal → $APP_ID"

    fi
fi

# ============================================================
# [8] Service Principal - Azure Owner
# ============================================================

echo
echo "[8] FortiCNAPP Service Principal - Azure Owner"
echo "------------------------------------------------------------"

SP_OWNER="false"

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

        SP_OWNER="true"
        ok "Service Principal has Azure Owner"

    else

        fail "Service Principal does not have Azure Owner."
        echo -e "      ${RED}${BOLD}REQUIRED / MISSING:${RESET}"
        echo -e "      ${RED}${BOLD}FortiCNAPP Service Principal → Azure Owner${RESET}"

        missing "FortiCNAPP Service Principal → Azure Owner"

    fi

else

    fail "Cannot check Azure Owner because Service Principal was not resolved."
    missing "FortiCNAPP Service Principal → Azure Owner"

fi

# ============================================================
# Function: Check Entra role for Service Principal
# ============================================================

check_sp_role() {

    local ROLE_NAME="$1"
    local SECTION="$2"

    echo
    echo "$SECTION"
    echo "------------------------------------------------------------"

    if [[ -z "$SP_OBJECT_ID" ]]; then

        fail "Cannot verify ${ROLE_NAME}; Service Principal was not resolved."
        missing "FortiCNAPP Service Principal → ${ROLE_NAME}"
        return

    fi

    ROLE_RESPONSE=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=displayName%20eq%20'${ROLE_NAME// /%20}'" \
        2>&1)

    if [[ $? -ne 0 ]]; then

        fail "Could not query ${ROLE_NAME} role definition."
        missing "FortiCNAPP Service Principal → ${ROLE_NAME} → Unable to query"

        return
    fi

    ROLE_ID=$(echo "$ROLE_RESPONSE" | jq -r '.value[0].id // empty')

    if [[ -z "$ROLE_ID" ]]; then

        fail "Could not find ${ROLE_NAME} role definition."
        missing "FortiCNAPP Service Principal → ${ROLE_NAME}"

        return
    fi

    ASSIGNMENT_RESPONSE=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$SP_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$ROLE_ID'" \
        2>&1)

    if [[ $? -ne 0 ]]; then

        fail "Could not verify ${ROLE_NAME}."
        echo -e "      ${RED}${BOLD}Microsoft Graph role-assignment query failed.${RESET}"
        missing "FortiCNAPP Service Principal → ${ROLE_NAME} → Unable to query"

        return
    fi

    COUNT=$(echo "$ASSIGNMENT_RESPONSE" | jq '.value | length')

    if [[ "$COUNT" -gt 0 ]]; then

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

check_sp_role \
    "Application Administrator" \
    "[9] FortiCNAPP Service Principal - Application Administrator"

# ============================================================
# [10] Service Principal - Privileged Role Administrator
# ============================================================

check_sp_role \
    "Privileged Role Administrator" \
    "[10] FortiCNAPP Service Principal - Privileged Role Administrator"

# ============================================================
# [11] Optional Directory Readers
# ============================================================

echo
echo "[11] Optional - Directory Readers"
echo "------------------------------------------------------------"

DIRECTORY_READER="false"

if [[ -n "$SP_OBJECT_ID" ]]; then

    DR_ROLE_RESPONSE=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=displayName%20eq%20'Directory%20Readers'" \
        2>/dev/null)

    DR_ROLE_ID=$(echo "$DR_ROLE_RESPONSE" | jq -r '.value[0].id // empty')

    if [[ -n "$DR_ROLE_ID" ]]; then

        DR_ASSIGNMENT=$(az rest \
            --method GET \
            --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$SP_OBJECT_ID'%20and%20roleDefinitionId%20eq%20'$DR_ROLE_ID'" \
            2>/dev/null)

        DR_COUNT=$(echo "$DR_ASSIGNMENT" | jq '.value | length' 2>/dev/null)

        if [[ "$DR_COUNT" -gt 0 ]]; then

            DIRECTORY_READER="true"
            ok "Directory Readers assigned"

        else

            warn "Directory Readers not assigned."
            echo "      Optional for Entra directory collection."

        fi

    else

        warn "Could not verify optional Directory Readers."

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

    echo -e "  ${GREEN}${BOLD}✔ No required prerequisites are missing.${RESET}"

else

    for ITEM in "${REQUIRED_MISSING[@]}"; do
        echo -e "  ${RED}${BOLD}✘ ${ITEM}${RESET}"
    done

fi

# ============================================================
# [13] Generate JSON
# ============================================================

echo
echo "[13] Generate JSON Report"
echo "------------------------------------------------------------"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    OVERALL_STATUS="FAIL"
elif [[ "$WARN_COUNT" -gt 0 ]]; then
    OVERALL_STATUS="WARN"
else
    OVERALL_STATUS="PASS"
fi

if [[ ${#REQUIRED_MISSING[@]} -gt 0 ]]; then
    MISSING_JSON=$(printf '%s\n' "${REQUIRED_MISSING[@]}" | jq -R . | jq -s .)
else
    MISSING_JSON="[]"
fi

jq -n \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg status "$OVERALL_STATUS" \
    --arg tenant_id "$TENANT_ID" \
    --arg subscription_id "$SUBSCRIPTION_ID" \
    --arg subscription_name "$SUBSCRIPTION_NAME" \
    --arg user "$USER_UPN" \
    --arg user_display_name "$USER_DISPLAY_NAME" \
    --arg user_object_id "$USER_OBJECT_ID" \
    --arg app_display_name "$APP_DISPLAY_NAME" \
    --arg app_client_id "$APP_ID" \
    --arg app_object_id "$APP_OBJECT_ID" \
    --arg sp_display_name "$SP_DISPLAY_NAME" \
    --arg sp_object_id "$SP_OBJECT_ID" \
    --argjson user_owner "$USER_OWNER" \
    --argjson sp_owner "$SP_OWNER" \
    --argjson directory_reader "$DIRECTORY_READER" \
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
echo "============================================================"
