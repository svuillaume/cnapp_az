#!/usr/bin/env bash
# FortiCNAPP Azure integration - onboard, check, delete (single script; bash 3.2 / macOS compatible)
#
#   ./forticnapp-azure.sh            # menu
#   ./forticnapp-azure.sh onboard    # create/reuse the app and assign all prerequisites
#                                    #   (Directory Readers, Reader, Key Vault) + optional 1-hour temporary credentials
#   ./forticnapp-azure.sh check      # pre-flight: verify an app holds every required role (read-only)
#   ./forticnapp-azure.sh delete     # remove what onboarding created (roles, secret, service principal, app)
#   ./forticnapp-azure.sh pim        # assign Directory Readers through PIM (Active, permanent) instead of the standard path
#
# Requirements: az CLI, logged in to the right tenant (az login).
# Callers need: Application Administrator to create the app, Privileged Role Administrator for Entra roles,
#               Owner / User Access Administrator on the target subscription(s).
#
# Common variables (skip prompts / automate):
#   SUBSCRIPTIONS="id1 id2" (onboard)  SUBSCRIPTION_ID="id" (delete)  SUBSCRIPTION_IDS="id1 id2" (check)
#   APP_ID="<client id>" or APP_NAME="<name>"
# onboard : CREATE_APP=true  CREATE_SECRET=true|false  GRANT_DIRECTORY_READER=true|false  KV_MODE=rbac|policy|none
#           SCOPE_MODE=subscriptions|all|mgmt-group  MGMT_GROUP_ID  TEMP_CREDS=true|false  TEMP_SUBSCRIPTION_ID  RUN_PREFLIGHT=true|false
# check   : KV_CHECK=true|false  REQUIRE_DIRECTORY_READER=true|false
# delete  : DRY_RUN=true  KEEP_APP=true  FORCE=true
# pim     : ASSIGNMENT_TYPE=active|eligible  DURATION=P365D  JUSTIFICATION="..."

set -euo pipefail

DIRECTORY_READERS_ROLE_TEMPLATE_ID="88d8e3e3-8f55-4a1e-953a-9b9898b8876b"
GRAPH="https://graph.microsoft.com/v1.0"
GUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
DEFAULT_SUBSCRIPTION_ID="152fd713-80e2-4c6a-8783-fd1197e15a34"

command -v az >/dev/null || { echo "az CLI required"; exit 1; }

# ======================================================================================
# Onboard
# ======================================================================================
fn_onboard() {
APP_ID="${APP_ID:-}"
APP_NAME="${APP_NAME:-}"
SCOPE_MODE="${SCOPE_MODE:-}"
SUBSCRIPTIONS="${SUBSCRIPTIONS:-}"
MGMT_GROUP_ID="${MGMT_GROUP_ID:-}"
KV_MODE="${KV_MODE:-}"
GRANT_DIRECTORY_READER="${GRANT_DIRECTORY_READER:-true}"
CREATE_SECRET="${CREATE_SECRET:-true}"


TENANT_ID=$(az account show --query tenantId -o tsv)
echo ">> Tenant: $TENANT_ID"


# Ask for the subscription(s) FIRST (scope of every Azure role assignment below)
if [[ -z "$SCOPE_MODE" ]]; then
  if [[ -n "$SUBSCRIPTIONS" ]]; then SCOPE_MODE="subscriptions"
  elif [[ -n "$MGMT_GROUP_ID" ]]; then SCOPE_MODE="mgmt-group"
  elif [[ -t 0 ]]; then
    read -r -p "Subscription ID(s), space or comma separated, or 'all' [$DEFAULT_SUBSCRIPTION_ID]: " SUB_INPUT
    SUB_INPUT="${SUB_INPUT:-$DEFAULT_SUBSCRIPTION_ID}"
    if [[ "$SUB_INPUT" == "all" ]]; then SCOPE_MODE="all"; else SCOPE_MODE="subscriptions"; SUBSCRIPTIONS="$SUB_INPUT"; fi
  else
    echo "Set SUBSCRIPTIONS (or SCOPE_MODE=all / MGMT_GROUP_ID) - no interactive terminal to prompt on."; exit 1
  fi
fi
if [[ "$SCOPE_MODE" == "subscriptions" ]]; then
  SUBSCRIPTIONS=$(printf '%s' "$SUBSCRIPTIONS" | tr ',' ' ' | sed 's#/subscriptions/##g')
  for s in $SUBSCRIPTIONS; do
    [[ "$s" =~ $GUID_RE ]] || { echo "Invalid subscription ID: $s"; exit 1; }
    az account show --subscription "$s" >/dev/null 2>&1 \
      || { echo "Subscription $s is not visible to this az login."; exit 1; }
  done
  echo ">> Subscription scope: $SUBSCRIPTIONS"
fi

# Ask for the app if not supplied via APP_ID / APP_NAME (name to create/reuse, or an existing client ID)
if [[ -z "$APP_ID" && -z "$APP_NAME" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Existing app name or client ID to reuse, or a NEW name to create: " APP_INPUT
    [[ -n "$APP_INPUT" ]] || { echo "No app provided."; exit 1; }
    if [[ "$APP_INPUT" =~ $GUID_RE ]]; then APP_ID="$APP_INPUT"; else APP_NAME="$APP_INPUT"; fi
  else
    echo "Set APP_ID (reuse) or APP_NAME (reuse/create) - no interactive terminal to prompt on."; exit 1
  fi
fi

# 1. App registration (single tenant, no redirect URI) ---------------------------
if [[ -n "$APP_ID" ]]; then
  APP_NAME=$(az ad app show --id "$APP_ID" --query displayName -o tsv) \
    || { echo "App with client ID $APP_ID not found."; exit 1; }
  echo ">> Using existing app registration: $APP_NAME ($APP_ID)"
else
  MATCHES=$(az ad app list --display-name "$APP_NAME" --query "[].appId" -o tsv)
  COUNT=$(printf '%s\n' "$MATCHES" | grep -c . || true)
  if [[ "$COUNT" -gt 1 ]]; then
    echo "Multiple apps named '$APP_NAME' - re-run with APP_ID set to one of:"
    printf '  %s\n' $MATCHES; exit 1
  elif [[ "$COUNT" -eq 1 ]]; then
    APP_ID="$MATCHES"
    echo ">> Reusing existing app registration: $APP_NAME ($APP_ID)"
  else
    # Never create silently: nothing with this name exists, so confirm first
    if [[ "${CREATE_APP:-}" != "true" ]]; then
      [[ -t 0 ]] || { echo "No app named '$APP_NAME' exists. Set CREATE_APP=true to create it."; exit 1; }
      read -r -p "No app named '$APP_NAME' exists in this tenant. Create it? [y/N]: " CREATE_ANS
      case "${CREATE_ANS:-N}" in y|Y|yes|YES) ;; *) echo "Not created. Re-run with the existing app's name or client ID."; exit 0 ;; esac
    fi
    APP_ID=$(az ad app create --display-name "$APP_NAME" \
              --sign-in-audience AzureADMyOrg --query appId -o tsv)
    echo ">> Created app registration: $APP_NAME ($APP_ID)"
  fi
fi

# Service principal (required for role assignments)
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
if [[ -z "$SP_OBJECT_ID" ]]; then
  SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  echo ">> Created service principal: $SP_OBJECT_ID"
fi

# Optional client secret (printed once - store it securely)
if [[ "$CREATE_SECRET" == "true" ]]; then
  CLIENT_SECRET=$(az ad app credential reset --id "$APP_ID" --append \
                  --display-name "forticnapp" --years 1 --query password -o tsv)
fi

# 2. Directory Reader (standard Entra process; PIM-eligible variant not covered) ---
if [[ "$GRANT_DIRECTORY_READER" == "true" ]]; then
  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"$SP_OBJECT_ID\",\"roleDefinitionId\":\"$DIRECTORY_READERS_ROLE_TEMPLATE_ID\",\"directoryScopeId\":\"/\"}" \
    >/dev/null && echo ">> Directory Reader assigned" \
    || echo "!! Directory Reader not assigned (already exists, no Privileged Role Administrator, or PIM enforced - then run forticnapp-azure.sh pim)"
fi

# 3. Reader on subscriptions or management group ---------------------------------
assign() { # role scope
  local out errtxt
  if out=$(az role assignment create --assignee-object-id "$SP_OBJECT_ID" \
      --assignee-principal-type ServicePrincipal --role "$1" --scope "$2" 2>&1); then
    echo ">> $1 -> $2"
  elif printf '%s' "$out" | grep -qi 'already exists'; then
    echo ">> $1 already assigned at $2"
  else
    errtxt=$(printf '%s\n' "$out" | tail -n 1)
    echo "!! $1 on $2 FAILED: $errtxt"
  fi
}

case "$SCOPE_MODE" in
  mgmt-group)
    [[ -n "$MGMT_GROUP_ID" ]] || { echo "MGMT_GROUP_ID required"; exit 1; }
    SCOPES=("/providers/Microsoft.Management/managementGroups/$MGMT_GROUP_ID") ;;
  subscriptions)
    SCOPES=(); for s in $SUBSCRIPTIONS; do SCOPES+=("/subscriptions/$s"); done ;;
  all)
    SCOPES=()
    while IFS= read -r s; do [[ -n "$s" ]] && SCOPES+=("/subscriptions/$s"); done \
      < <(az account list --query "[?state=='Enabled'].id" -o tsv) ;;
  *) echo "Invalid SCOPE_MODE"; exit 1 ;;
esac

# Guard (bash 3.2 treats empty arrays as unbound under set -u)
if [[ ${#SCOPES[@]} -eq 0 ]]; then echo "No scopes resolved - nothing to assign."; exit 1; fi

for scope in "${SCOPES[@]}"; do assign "Reader" "$scope"; done

# 4. Key Vault permissions (Azure Configuration integrations only) ---------------
echo
echo "=== Key Vault prerequisites (only needed for Azure Configuration / compliance integrations) ==="
if [[ -z "$KV_MODE" ]]; then
  if [[ -t 0 ]]; then
    echo "Key Vault access method:"
    echo "  1) Azure RBAC - assign 'Key Vault Reader' (recommended; new vaults covered automatically)"
    echo "  2) Vault access policy - List on keys and secrets, per vault"
    echo "  3) Skip (not a Configuration integration)"
    read -r -p "Choose [1]: " KV_CHOICE
    case "${KV_CHOICE:-1}" in 1) KV_MODE=rbac ;; 2) KV_MODE=policy ;; 3) KV_MODE=none ;; *) echo "Invalid choice"; exit 1 ;; esac
  else
    KV_MODE=rbac   # non-interactive default
  fi
fi
echo ">> Key Vault mode: $KV_MODE"

# Inventory vaults and their permission model (RBAC role has no effect on access-policy vaults)
KV_TOTAL=0; KV_NON_RBAC=0; KV_POLICY_SET=0
if [[ "$KV_MODE" != "none" ]]; then
  for scope in "${SCOPES[@]}"; do
    [[ "$scope" == /subscriptions/* ]] || { echo "   (vault inventory skipped for $scope: management group scope)"; continue; }
    sub="${scope#/subscriptions/}"
    while IFS= read -r kv; do
      [[ -n "$kv" ]] || continue
      KV_TOTAL=$((KV_TOTAL+1))
      rbac=$(az keyvault show --subscription "$sub" --name "$kv" \
             --query "properties.enableRbacAuthorization" -o tsv 2>/dev/null || echo "unknown")
      if [[ "$rbac" != "true" ]]; then KV_NON_RBAC=$((KV_NON_RBAC+1)); fi
      MODEL="access policy"
      if [[ "$rbac" == "true" ]]; then MODEL="Azure RBAC"; fi
      echo "   vault $kv (sub ${sub}): permission model = $MODEL"
      if [[ "$KV_MODE" == "policy" && "$rbac" != "true" ]]; then
        az keyvault set-policy --subscription "$sub" --name "$kv" --object-id "$SP_OBJECT_ID" \
          --key-permissions list --secret-permissions list >/dev/null 2>&1 \
          && { echo "   >> Access policy set on $kv"; KV_POLICY_SET=$((KV_POLICY_SET+1)); } \
          || echo "   !! $kv: could not set access policy (insufficient rights?)"
      elif [[ "$KV_MODE" == "policy" ]]; then
        echo "   !! $kv uses Azure RBAC - access policies do not apply; use KV_MODE=rbac"
      fi
    done < <(az keyvault list --subscription "$sub" --query "[].name" -o tsv 2>/dev/null)
  done
fi

if [[ "$KV_MODE" == "rbac" ]]; then
  for scope in "${SCOPES[@]}"; do assign "Key Vault Reader" "$scope"; done
  if [[ "$KV_NON_RBAC" -gt 0 ]]; then
    echo "!! $KV_NON_RBAC vault(s) use the access-policy model: the RBAC role will NOT grant access there."
    echo "   Either enable the Azure RBAC permission model on them, or re-run with KV_MODE=policy."
  fi
fi

# Output for the FortiCNAPP integration wizard ----------------------------------
echo
echo "=========== Values for FortiCNAPP ==========="
echo "Tenant ID     : $TENANT_ID"
echo "Client ID     : $APP_ID"
[[ "${CLIENT_SECRET:-}" ]] && echo "Client Secret : $CLIENT_SECRET   (shown once)"
echo "Subscriptions : ${#SCOPES[@]} scope(s) assigned"
echo "Key Vault     : mode=$KV_MODE, vaults found=$KV_TOTAL, access-policy vaults=$KV_NON_RBAC, policies set=$KV_POLICY_SET"

# Pre-flight check: verify the app holds every required role
RUN_PREFLIGHT="${RUN_PREFLIGHT:-}"
if [[ "$RUN_PREFLIGHT" != "false" ]]; then
  if [[ -z "$RUN_PREFLIGHT" && -t 0 ]]; then
    read -r -p "Run the pre-flight check now to verify all required roles? [Y/n]: " PF_ANS
    case "${PF_ANS:-Y}" in n|N|no|NO) RUN_PREFLIGHT=false ;; *) RUN_PREFLIGHT=true ;; esac
  fi
  if [[ "$RUN_PREFLIGHT" == "true" ]]; then
    PF_SUBS=""
    for s in "${SCOPES[@]}"; do [[ "$s" == /subscriptions/* ]] && PF_SUBS="$PF_SUBS ${s#/subscriptions/}"; done
    PF_KV=true; [[ "$KV_MODE" == "none" ]] && PF_KV=false
    echo; echo ">> Waiting 20s for role assignments to propagate, then running the pre-flight check ..."
    sleep 20
    set +e
    ( set -euo pipefail; APP_ID="$APP_ID" SUBSCRIPTION_IDS="${PF_SUBS# }" KV_CHECK="$PF_KV" fn_check )
    set -e
  fi
fi


# 5. Temporary credentials (LAST STEP, after the app prerequisites) ---------------------
# Creates a SEPARATE service principal: Owner on the subscription + Entra roles Application Administrator and
# Privileged Role Administrator, with a client secret that expires in one hour. Used only for FortiCNAPP's
# automated onboarding. These are very high privileges: use right away, then run the cleanup commands printed below.
TEMP_CREDS="${TEMP_CREDS:-}"
if [[ -z "$TEMP_CREDS" ]]; then
  if [[ -t 0 ]]; then
    echo
    echo "=== Optional: temporary credentials for FortiCNAPP automated onboarding ==="
    echo "Creates a SEPARATE service principal with Owner on the subscription plus the Entra roles"
    echo "Application Administrator and Privileged Role Administrator. Its secret expires in 1 hour."
    echo "These are very high privileges - continue only if you will use them right away."
    read -r -p "Generate temporary credentials now? [y/N]: " TC_ANS
    case "${TC_ANS:-N}" in y|Y|yes|YES) TEMP_CREDS=true ;; *) TEMP_CREDS=false ;; esac
  else
    TEMP_CREDS=false
  fi
fi

if [[ "$TEMP_CREDS" == "true" ]]; then
  APP_ADMIN_ROLE_ID="9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3"      # Application Administrator
  PRIV_ROLE_ADMIN_ID="e8611ab8-c189-46e8-94e1-60213ab1f814"     # Privileged Role Administrator

  # Which subscription gets the temporary Owner role (the doc uses a single subscription)
  TEMP_SUBS=""
  for s in "${SCOPES[@]}"; do
    if [[ "$s" == /subscriptions/* ]]; then TEMP_SUBS="$TEMP_SUBS ${s#/subscriptions/}"; fi
  done
  TEMP_SUBS="${TEMP_SUBS# }"
  TEMP_SUB="${TEMP_SUBSCRIPTION_ID:-}"
  if [[ -z "$TEMP_SUB" ]]; then
    TEMP_COUNT=$(printf '%s\n' $TEMP_SUBS | grep -c . || true)
    if [[ "$TEMP_COUNT" -eq 1 ]]; then
      TEMP_SUB="$TEMP_SUBS"
    elif [[ -t 0 ]]; then
      read -r -p "Subscription ID for the temporary Owner role [${TEMP_SUBS%% *}]: " TEMP_SUB_IN
      TEMP_SUB="${TEMP_SUB_IN:-${TEMP_SUBS%% *}}"
    else
      TEMP_SUB="${TEMP_SUBS%% *}"
    fi
  fi
  TEMP_SUB="${TEMP_SUB#/subscriptions/}"
  [[ "$TEMP_SUB" =~ $GUID_RE ]] || { echo "No valid subscription ID for the temporary credentials."; exit 1; }

  TEMP_NAME="forticnapp-temp-onboarding-$(date -u +%Y%m%d%H%M)"
  # BSD date (macOS) uses -v, GNU date uses -d
  EXPIRY=$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)

  echo
  echo ">> Creating temporary service principal $TEMP_NAME (Owner on /subscriptions/$TEMP_SUB) ..."
  TEMP_APP_ID=$(az ad sp create-for-rbac --name "$TEMP_NAME" --role Owner \
                --scopes "/subscriptions/$TEMP_SUB" --query appId -o tsv)
  TEMP_SP_OBJECT_ID=$(az ad sp show --id "$TEMP_APP_ID" --query id -o tsv)

  echo ">> Resetting its secret to expire at $EXPIRY (UTC)"
  TEMP_SECRET=$(az ad sp credential reset --id "$TEMP_APP_ID" --end-date "$EXPIRY" --query password -o tsv)

  GRAPH_URL="https://graph.microsoft.com/v1.0"
  entra_role_present() { # roleDefinitionId -> 0 if the temp SP holds it (standard or PIM-active)
    local rid="$1" f n1 n2
    f="\$filter=principalId eq '$TEMP_SP_OBJECT_ID' and roleDefinitionId eq '$rid'"
    n1=$(az rest --method GET --uri "$GRAPH_URL/roleManagement/directory/roleAssignments?$f" --query "length(value)" -o tsv 2>/dev/null || echo 0)
    n2=$(az rest --method GET --uri "$GRAPH_URL/roleManagement/directory/roleAssignmentScheduleInstances?$f" --query "length(value)" -o tsv 2>/dev/null || echo 0)
    [[ "${n1:-0}" != "0" || "${n2:-0}" != "0" ]]
  }
  assign_entra_role() { # roleDefinitionId, label
    local rid="$1" label="$2" body err errtxt nowiso
    body="{\"principalId\":\"$TEMP_SP_OBJECT_ID\",\"roleDefinitionId\":\"$rid\",\"directoryScopeId\":\"/\"}"
    if err=$(az rest --method POST --uri "$GRAPH_URL/roleManagement/directory/roleAssignments" \
             --headers "Content-Type=application/json" --body "$body" 2>&1); then
      echo ">> Entra role assigned: $label"; return 0
    fi
    # Fallback for PIM tenants: active assignment through a schedule request, limited to 2 hours
    nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    body="{\"action\":\"adminAssign\",\"principalId\":\"$TEMP_SP_OBJECT_ID\",\"roleDefinitionId\":\"$rid\",\"directoryScopeId\":\"/\",\"justification\":\"FortiCNAPP temporary onboarding\",\"scheduleInfo\":{\"startDateTime\":\"$nowiso\",\"expiration\":{\"type\":\"afterDuration\",\"duration\":\"PT2H\"}}}"
    if err=$(az rest --method POST --uri "$GRAPH_URL/roleManagement/directory/roleAssignmentScheduleRequests" \
             --headers "Content-Type=application/json" --body "$body" 2>&1); then
      echo ">> Entra role assigned via PIM (active, 2 hours): $label"; return 0
    fi
    errtxt=$(printf '%s\n' "$err" | tail -n 1)
    echo "!! Could not assign Entra role $label: $errtxt"
    return 1
  }

  assign_entra_role "$APP_ADMIN_ROLE_ID" "Application Administrator" || true
  assign_entra_role "$PRIV_ROLE_ADMIN_ID" "Privileged Role Administrator" || true

  # Verify, allowing a short propagation delay
  echo ">> Verifying the Entra role assignments (up to ~60s) ..."
  for _try in 1 2 3 4; do
    if entra_role_present "$APP_ADMIN_ROLE_ID" && entra_role_present "$PRIV_ROLE_ADMIN_ID"; then ENTRA_VERIFIED=true; break; fi
    ENTRA_VERIFIED=false; sleep 15
  done
  if [[ "$ENTRA_VERIFIED" == "true" ]]; then
    echo ">> Verified: the temporary service principal holds both Entra roles."
  else
    echo "!! NOT verified: the temporary service principal does not hold both Entra roles yet."
    echo "   FortiCNAPP's terraform apply will fail with 403 Authorization_RequestDenied until it does."
    echo "   Assign Application Administrator and Privileged Role Administrator to $TEMP_APP_ID in Entra admin center"
    echo "   (Roles & admins), wait a few minutes, then retry the onboarding."
  fi

  echo
  echo "======= TEMPORARY CREDENTIALS (expire $EXPIRY UTC) ======="
  echo "Client ID       : $TEMP_APP_ID"
  echo "Client Secret   : $TEMP_SECRET   (shown once)"
  echo "Subscription ID : $TEMP_SUB"
  echo "Tenant ID       : $TENANT_ID"
  echo "==========================================================="
  echo "Paste these into the FortiCNAPP onboarding wizard now. Do not store them."
  echo
  echo "Clean up when finished (the secret expires in 1 hour, but the roles do not):"
  echo "  ./forticnapp-azure.sh delete      # then enter client ID $TEMP_APP_ID to delete the temporary app"
  echo "  or: az ad app delete --id $TEMP_APP_ID   (deletes the app and its service principal; then check Entra Roles & admins for leftover assignments)"
  echo "  and remove its Owner assignment: az role assignment delete --assignee $TEMP_SP_OBJECT_ID --role Owner --scope /subscriptions/$TEMP_SUB"
fi
}

# ======================================================================================
# Pre-flight check (read-only)
# ======================================================================================
fn_check() {
APP_ID="${APP_ID:-}"
APP_NAME="${APP_NAME:-}"
SUBSCRIPTION_IDS="${SUBSCRIPTION_IDS:-}"
KV_CHECK="${KV_CHECK:-}"
REQUIRE_DIRECTORY_READER="${REQUIRE_DIRECTORY_READER:-true}"


if [[ -t 1 ]]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else G=""; Y=""; R=""; N=""; fi
PASS=0; WARN=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ${G}[PASS]${N} $*"; }
warn() { WARN=$((WARN+1)); echo "  ${Y}[WARN]${N} $*"; }
fail() { FAIL=$((FAIL+1)); echo "  ${R}[FAIL]${N} $*"; }

# --- Inputs ------------------------------------------------------------------------
if [[ -z "$APP_ID" && -z "$APP_NAME" ]]; then
  [[ -t 0 ]] || { echo "Set APP_ID or APP_NAME (no interactive terminal)."; exit 1; }
  read -r -p "App registration name or Application (client) ID: " APP_INPUT
  [[ -n "$APP_INPUT" ]] || { echo "No app provided."; exit 1; }
  if [[ "$APP_INPUT" =~ $GUID_RE ]]; then APP_ID="$APP_INPUT"; else APP_NAME="$APP_INPUT"; fi
fi
if [[ -z "$SUBSCRIPTION_IDS" ]]; then
  [[ -t 0 ]] || { echo "Set SUBSCRIPTION_IDS (no interactive terminal)."; exit 1; }
  read -r -p "Subscription ID(s), space or comma separated [$DEFAULT_SUBSCRIPTION_ID]: " SUB_INPUT
  SUBSCRIPTION_IDS="${SUB_INPUT:-$DEFAULT_SUBSCRIPTION_ID}"
fi
if [[ -z "$KV_CHECK" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Azure Configuration (compliance) integration? Check Key Vault access too [Y/n]: " KV_ANS
    case "${KV_ANS:-Y}" in n|N|no|NO) KV_CHECK=false ;; *) KV_CHECK=true ;; esac
  else
    KV_CHECK=true
  fi
fi
SUBS=$(printf '%s' "$SUBSCRIPTION_IDS" | tr ',' ' ' | sed 's#/subscriptions/##g')

# --- 1. App registration & service principal ---------------------------------------
echo
echo "== 1. App registration (Entra ID) =="
if [[ -z "$APP_ID" ]]; then
  MATCHES=$(az ad app list --display-name "$APP_NAME" --query "[].appId" -o tsv)
  COUNT=$(printf '%s\n' "$MATCHES" | grep -c . || true)
  if [[ "$COUNT" -eq 0 ]]; then echo "  ${R}[FAIL]${N} App '$APP_NAME' not found."; exit 1; fi
  if [[ "$COUNT" -gt 1 ]]; then
    echo "  Multiple apps named '$APP_NAME' - re-run with APP_ID set to one of:"; printf '    %s\n' $MATCHES; exit 1
  fi
  APP_ID="$MATCHES"
fi
if ! APP_DISPLAY=$(az ad app show --id "$APP_ID" --query displayName -o tsv 2>/dev/null); then
  echo "  ${R}[FAIL]${N} App with client ID $APP_ID not found in this tenant."; exit 1
fi
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "  App: $APP_DISPLAY ($APP_ID)   Tenant: $TENANT_ID"
pass "App registration exists"

AUDIENCE=$(az ad app show --id "$APP_ID" --query signInAudience -o tsv)
if [[ "$AUDIENCE" == "AzureADMyOrg" ]]; then pass "Supported account types: this organizational directory only"
else warn "Supported account types is '$AUDIENCE' (doc recommends AzureADMyOrg)"; fi

REDIRECTS=$(az ad app show --id "$APP_ID" --query "length(web.redirectUris) + length(spa.redirectUris) + length(publicClient.redirectUris)" -o tsv 2>/dev/null || echo 0)
if [[ "${REDIRECTS:-0}" == "0" ]]; then pass "No redirect URIs (as required)"; else warn "App has $REDIRECTS redirect URI(s); the doc says to leave this empty"; fi

SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
if [[ -z "$SP_OBJECT_ID" ]]; then
  fail "No service principal for this app - role assignments cannot exist (create it: az ad sp create --id $APP_ID)"
  echo; echo "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"; exit 1
fi
pass "Service principal exists ($SP_OBJECT_ID)"

# Client secret
NOW=$(date -u +%Y-%m-%dT%H:%M:%S)
SOON=$(date -u -v+30d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '+30 days' +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")
SECRET_COUNT=0; VALID_SECRETS=0; SOON_SECRETS=0
while IFS=$'\t' read -r sname send; do
  [[ -n "${send:-}" ]] || continue
  SECRET_COUNT=$((SECRET_COUNT+1))
  e="${send:0:19}"
  if [[ "$e" > "$NOW" ]]; then
    VALID_SECRETS=$((VALID_SECRETS+1))
    if [[ -n "$SOON" && ! "$e" > "$SOON" ]]; then SOON_SECRETS=$((SOON_SECRETS+1)); fi
  fi
done < <(az ad app credential list --id "$APP_ID" --query "[].[displayName,endDateTime]" -o tsv 2>/dev/null)
if [[ "$VALID_SECRETS" -gt 0 ]]; then
  pass "Client secret present and not expired ($VALID_SECRETS valid of $SECRET_COUNT)"
  [[ "$SOON_SECRETS" -gt 0 ]] && warn "$SOON_SECRETS secret(s) expire within 30 days"
elif [[ "$SECRET_COUNT" -gt 0 ]]; then
  fail "All $SECRET_COUNT client secret(s) are expired"
else
  fail "No client secret found (the integration needs tenant ID, client ID and a client secret)"
fi

# --- 2. Entra ID role: Directory Readers -------------------------------------------
echo
echo "== 2. Entra ID role: Directory Readers =="
DR_FILTER="\$filter=principalId eq '$SP_OBJECT_ID' and roleDefinitionId eq '$DIRECTORY_READERS_ROLE_TEMPLATE_ID'"
DR_STD=$(az rest --method GET --uri "$GRAPH/roleManagement/directory/roleAssignments?$DR_FILTER" --query "length(value)" -o tsv 2>/dev/null || echo "?")
DR_ACT=$(az rest --method GET --uri "$GRAPH/roleManagement/directory/roleAssignmentScheduleInstances?$DR_FILTER" --query "length(value)" -o tsv 2>/dev/null || echo "?")
DR_ELI=$(az rest --method GET --uri "$GRAPH/roleManagement/directory/roleEligibilityScheduleInstances?$DR_FILTER" --query "length(value)" -o tsv 2>/dev/null || echo "?")
# "?" means that endpoint could not be read; never count it as an assignment
PIM_UNREADABLE=false
if [[ "$DR_ACT" == "?" || "$DR_ELI" == "?" ]]; then PIM_UNREADABLE=true; fi
if [[ "$DR_STD" == "?" ]]; then DR_STD=0; fi
if [[ "$DR_ACT" == "?" ]]; then DR_ACT=0; fi
if [[ "$DR_ELI" == "?" ]]; then DR_ELI=0; fi
if [[ "$DR_STD" != "0" || "$DR_ACT" != "0" ]]; then
  pass "Directory Readers is assigned (standard=$DR_STD, PIM-active=$DR_ACT)"
  if [[ "$PIM_UNREADABLE" == "true" ]]; then warn "PIM schedule data not readable with this login (needs RoleManagement.Read.Directory / PIM licence); result based on what could be read"; fi
elif [[ "$DR_ELI" != "0" ]]; then
  fail "Directory Readers is only ELIGIBLE (PIM). An app cannot activate it - make it an Active assignment"
elif [[ "$PIM_UNREADABLE" == "true" ]]; then
  warn "Directory Readers: no standard assignment found and PIM data could not be read - cannot confirm (re-login with the RoleManagement.Read.Directory scope)"
elif [[ "$REQUIRE_DIRECTORY_READER" == "true" ]]; then
  fail "Directory Readers is not assigned (doc marks it optional; set REQUIRE_DIRECTORY_READER=false to downgrade)"
else
  warn "Directory Readers is not assigned (optional per the doc)"
fi

# --- 3. Subscriptions: Reader --------------------------------------------------------
for sub in $SUBS; do
  echo
  echo "== 3. Subscription $sub =="
  if ! [[ "$sub" =~ $GUID_RE ]]; then fail "Not a valid subscription ID: $sub"; continue; fi
  if ! SUB_NAME=$(az account show --subscription "$sub" --query name -o tsv 2>/dev/null); then
    fail "Subscription not visible to the current az login"; continue
  fi
  echo "  Name: $SUB_NAME"
  READER=$(az role assignment list --subscription "$sub" --assignee "$SP_OBJECT_ID" --include-inherited \
           --query "[?roleDefinitionName=='Reader'].scope" -o tsv 2>/dev/null || true)
  if [[ -n "$READER" ]]; then
    READER_FIRST=$(printf '%s\n' "$READER" | head -n 1)
    pass "Reader assigned at: $READER_FIRST"
  else
    # Owner / Contributor include */read, so they already cover Reader (but are broader than least privilege)
    BROADER=$(az role assignment list --subscription "$sub" --assignee "$SP_OBJECT_ID" --include-inherited \
              --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='Contributor'].[roleDefinitionName,scope]" \
              -o tsv 2>/dev/null | head -n1 | tr '\t' ' ' || true)
    if [[ -n "$BROADER" ]]; then
      warn "No explicit Reader, but covered by: $BROADER (includes read access; broader than the least-privilege Reader)"
    else
      OTHER=$(az role assignment list --subscription "$sub" --assignee "$SP_OBJECT_ID" --include-inherited \
              --query "[].roleDefinitionName" -o tsv 2>/dev/null | tr '\n' ',' || true)
      OTHER_TXT=""
      if [[ -n "$OTHER" ]]; then OTHER_TXT=" - app holds: ${OTHER%,}"; fi
      fail "Reader role NOT assigned on this subscription$OTHER_TXT"
    fi
  fi

  # --- 4. Key Vault ---
  if [[ "$KV_CHECK" == "true" ]]; then
    echo "  -- Key Vault access (Azure Configuration integrations) --"
    KV_FOUND=0
    while IFS= read -r kv; do
      [[ -n "$kv" ]] || continue
      KV_FOUND=$((KV_FOUND+1))
      kvid=$(az keyvault show --subscription "$sub" --name "$kv" --query id -o tsv 2>/dev/null || true)
      rbac=$(az keyvault show --subscription "$sub" --name "$kv" --query "properties.enableRbacAuthorization" -o tsv 2>/dev/null || echo "")
      if [[ "$rbac" == "true" ]]; then
        hit=$(az role assignment list --scope "$kvid" --assignee "$SP_OBJECT_ID" --include-inherited \
              --query "[?roleDefinitionName=='Key Vault Reader'].scope" -o tsv 2>/dev/null | head -n1 || true)
        if [[ -n "$hit" ]]; then pass "$kv (Azure RBAC): Key Vault Reader at $hit"
        else
          kvbroad=$(az role assignment list --scope "$kvid" --assignee "$SP_OBJECT_ID" --include-inherited \
                    --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='Contributor'].[roleDefinitionName,scope]" \
                    -o tsv 2>/dev/null | head -n1 | tr '\t' ' ' || true)
          if [[ -n "$kvbroad" ]]; then warn "$kv (Azure RBAC): no Key Vault Reader, but covered by $kvbroad (management-plane read; broader than needed)"
          else fail "$kv (Azure RBAC): 'Key Vault Reader' NOT assigned (policies will show 'Could Not Assess')"; fi
        fi
      else
        ok=$(az keyvault show --subscription "$sub" --name "$kv" \
             --query "length(properties.accessPolicies[?objectId=='$SP_OBJECT_ID' && contains(permissions.keys,'list') && contains(permissions.secrets,'list')])" \
             -o tsv 2>/dev/null || echo 0)
        if [[ "${ok:-0}" != "0" ]]; then pass "$kv (access policy): List on keys and secrets present"
        else fail "$kv (access policy): no policy with List on keys + secrets for this app"; fi
      fi
    done < <(az keyvault list --subscription "$sub" --query "[].name" -o tsv 2>/dev/null)
    if [[ "$KV_FOUND" -eq 0 ]]; then
      RBAC_ROLE=$(az role assignment list --subscription "$sub" --assignee "$SP_OBJECT_ID" --include-inherited \
                  --query "[?roleDefinitionName=='Key Vault Reader'].scope" -o tsv 2>/dev/null | head -n1 || true)
      if [[ -n "$RBAC_ROLE" ]]; then pass "No vaults yet; Key Vault Reader already assigned at $RBAC_ROLE (future vaults covered)"
      else warn "No vaults in this subscription; Key Vault Reader not assigned, so future RBAC vaults would not be covered"; fi
    fi
  fi
done

# --- Summary -------------------------------------------------------------------------
echo
echo "================ PRE-FLIGHT SUMMARY ================"
echo "App: $APP_DISPLAY ($APP_ID)"
echo "${G}PASS=$PASS${N}  ${Y}WARN=$WARN${N}  ${R}FAIL=$FAIL${N}"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: NOT READY - fix the FAIL items above (re-run forticnapp-azure.sh onboard or forticnapp-azure.sh pim), then re-check."
  echo "Note: new role assignments can take a few minutes to propagate."
  exit 1
fi
echo "Result: READY for the FortiCNAPP Azure integration."
}

# ======================================================================================
# Delete / offboard
# ======================================================================================
fn_delete() {
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
APP_ID="${APP_ID:-}"
APP_NAME="${APP_NAME:-}"
DRY_RUN="${DRY_RUN:-false}"
KEEP_APP="${KEEP_APP:-false}"
FORCE="${FORCE:-false}"


TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
: > "$TMP/roles.tsv"; : > "$TMP/others.tsv"; : > "$TMP/kv.txt"; : > "$TMP/dir_std.txt"

TENANT_ID=$(az account show --query tenantId -o tsv)
echo ">> Tenant: $TENANT_ID"

# --- Which subscription? (asked first; scope of this teardown) ------------------------
if [[ -z "$SUBSCRIPTION_ID" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Subscription ID to clean up [$DEFAULT_SUBSCRIPTION_ID]: " SUB_INPUT
    SUBSCRIPTION_ID="${SUB_INPUT:-$DEFAULT_SUBSCRIPTION_ID}"
  else
    echo "Set SUBSCRIPTION_ID (no interactive terminal to prompt on)."; exit 1
  fi
fi
SUBSCRIPTION_ID="${SUBSCRIPTION_ID#/subscriptions/}"   # accept /subscriptions/<id> or <id>
[[ "$SUBSCRIPTION_ID" =~ $GUID_RE ]] || { echo "Invalid subscription ID: $SUBSCRIPTION_ID"; exit 1; }
az account show --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1 \
  || { echo "Subscription $SUBSCRIPTION_ID is not visible to this az login."; exit 1; }
echo ">> Subscription: $SUBSCRIPTION_ID"

# --- Which app? --------------------------------------------------------------------
if [[ -z "$APP_ID" && -z "$APP_NAME" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "App registration name or Application (client) ID to remove: " APP_INPUT
    [[ -n "$APP_INPUT" ]] || { echo "No app provided."; exit 1; }
    if [[ "$APP_INPUT" =~ $GUID_RE ]]; then APP_ID="$APP_INPUT"; else APP_NAME="$APP_INPUT"; fi
  else
    echo "Set APP_ID or APP_NAME (no interactive terminal to prompt on)."; exit 1
  fi
fi

if [[ -z "$APP_ID" ]]; then
  MATCHES=$(az ad app list --display-name "$APP_NAME" --query "[].appId" -o tsv)
  COUNT=$(printf '%s\n' "$MATCHES" | grep -c . || true)
  if [[ "$COUNT" -eq 0 ]]; then echo "App '$APP_NAME' not found."; exit 1; fi
  if [[ "$COUNT" -gt 1 ]]; then
    echo "Multiple apps named '$APP_NAME' - re-run with APP_ID set to one of:"
    printf '  %s\n' $MATCHES; exit 1
  fi
  APP_ID="$MATCHES"
fi
APP_DISPLAY=$(az ad app show --id "$APP_ID" --query displayName -o tsv) \
  || { echo "App with client ID $APP_ID not found."; exit 1; }
APP_OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
echo ">> App: $APP_DISPLAY ($APP_ID)"
[[ -n "$SP_OBJECT_ID" ]] && echo ">> Service principal: $SP_OBJECT_ID" || echo ">> No service principal found - permission cleanup will be skipped"

# --- Build the plan ----------------------------------------------------------------
SUBS="$SUBSCRIPTION_ID"
ROLE_FILTER="[?roleDefinitionName=='Reader' || roleDefinitionName=='Key Vault Reader'].[id,roleDefinitionName,scope]"
OTHER_FILTER="[?roleDefinitionName!='Reader' && roleDefinitionName!='Key Vault Reader'].[roleDefinitionName,scope]"
DIR_ACTIVE=0; DIR_ELIGIBLE=0

if [[ -n "$SP_OBJECT_ID" ]]; then
  echo ">> Scanning Azure role assignments and Key Vaults ..."
  for sub in $SUBS; do
    az role assignment list --subscription "$sub" --all --assignee "$SP_OBJECT_ID" \
      --query "$ROLE_FILTER" -o tsv 2>/dev/null >> "$TMP/roles.tsv" || true
    az role assignment list --subscription "$sub" --all --assignee "$SP_OBJECT_ID" \
      --query "$OTHER_FILTER" -o tsv 2>/dev/null >> "$TMP/others.tsv" || true
    for kv in $(az keyvault list --subscription "$sub" --query "[].name" -o tsv 2>/dev/null); do
      n=$(az keyvault show --subscription "$sub" --name "$kv" \
          --query "length(properties.accessPolicies[?objectId=='$SP_OBJECT_ID'])" -o tsv 2>/dev/null || echo 0)
      [[ "${n:-0}" != "0" ]] && echo "$sub|$kv" >> "$TMP/kv.txt"
    done
  done

  echo ">> Scanning Entra Directory Readers assignments ..."
  DR_FILTER="\$filter=principalId eq '$SP_OBJECT_ID' and roleDefinitionId eq '$DIRECTORY_READERS_ROLE_TEMPLATE_ID'"
  az rest --method GET --uri "$GRAPH/roleManagement/directory/roleAssignments?$DR_FILTER" \
    --query "value[].id" -o tsv 2>/dev/null >> "$TMP/dir_std.txt" || true
  DIR_ACTIVE=$(az rest --method GET --uri "$GRAPH/roleManagement/directory/roleAssignmentScheduleInstances?$DR_FILTER" \
    --query "length(value)" -o tsv 2>/dev/null || echo 0)
  DIR_ELIGIBLE=$(az rest --method GET --uri "$GRAPH/roleManagement/directory/roleEligibilityScheduleInstances?$DR_FILTER" \
    --query "length(value)" -o tsv 2>/dev/null || echo 0)
fi

SECRET_IDS=$(az ad app credential list --id "$APP_ID" --query "[?displayName=='forticnapp'].keyId" -o tsv 2>/dev/null || true)

# --- Show the plan -----------------------------------------------------------------
echo
echo "================ TEARDOWN PLAN ================"
echo "Subscription     : $SUBSCRIPTION_ID  (only this subscription is touched)"
APP_ACTION="DELETE - tenant-wide, with its service principal"
if [[ "$KEEP_APP" == "true" ]]; then APP_ACTION="KEEP"; fi
echo "App registration : $APP_DISPLAY [$APP_ID]  -> $APP_ACTION"
echo "Azure roles (Reader / Key Vault Reader) in this subscription:"
if [[ -s "$TMP/roles.tsv" ]]; then while IFS=$'\t' read -r _id role scope; do echo "   - $role @ $scope"; done < "$TMP/roles.tsv"; else echo "   (none found)"; fi
echo "Key Vault access policies:"
if [[ -s "$TMP/kv.txt" ]]; then while IFS='|' read -r sub kv; do echo "   - vault $kv (sub $sub)"; done < "$TMP/kv.txt"; else echo "   (none found)"; fi
DIR_STD_COUNT=$(grep -c . "$TMP/dir_std.txt" || true)
echo "Entra Directory Readers (tenant-wide, not subscription-scoped): standard=$DIR_STD_COUNT  PIM-active=${DIR_ACTIVE:-0}  PIM-eligible=${DIR_ELIGIBLE:-0}"
SECRET_COUNT=$(printf '%s\n' "$SECRET_IDS" | grep -c . || true)
echo "Client secrets named forticnapp: $SECRET_COUNT"
if [[ -s "$TMP/others.tsv" ]]; then
  echo "Other role assignments held by the app (NOT removed by this script):"
  while IFS=$'\t' read -r role scope; do echo "   - $role @ $scope"; done < "$TMP/others.tsv"
fi
MODE_TXT="LIVE"
if [[ "$DRY_RUN" == "true" ]]; then MODE_TXT="DRY RUN, no changes"; fi
echo "Mode: $MODE_TXT"
echo "==============================================="

if [[ "$DRY_RUN" == "true" ]]; then echo "Dry run complete."; exit 0; fi

if [[ "$FORCE" != "true" ]]; then
  [[ -t 0 ]] || { echo "Non-interactive: set FORCE=true to proceed."; exit 1; }
  read -r -p "Type the app name ($APP_DISPLAY) to confirm deletion: " CONFIRM
  [[ "$CONFIRM" == "$APP_DISPLAY" ]] || { echo "Confirmation did not match. Nothing changed."; exit 1; }
fi

step() { # description, then command...  (shows the real error text instead of hiding it)
  local d="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    echo ">> $d"
  else
    err=$(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')
    echo "!! $d - FAILED: $err"
  fi
  return 0
}

# 1. Key Vault access policies
while IFS='|' read -r sub kv; do
  [[ -n "$kv" ]] || continue
  step "Removed access policy on $kv" az keyvault delete-policy --subscription "$sub" --name "$kv" --object-id "$SP_OBJECT_ID"
done < "$TMP/kv.txt"

# 2. Azure role assignments
while IFS=$'\t' read -r id role scope; do
  [[ -n "$id" ]] || continue
  step "Removed $role @ $scope" az role assignment delete --ids "$id"
done < "$TMP/roles.tsv"

# 3. Entra Directory Readers (standard, then PIM active, then PIM eligible)
REMOVE_BODY="{\"action\":\"adminRemove\",\"principalId\":\"$SP_OBJECT_ID\",\"roleDefinitionId\":\"$DIRECTORY_READERS_ROLE_TEMPLATE_ID\",\"directoryScopeId\":\"/\"}"
while IFS= read -r rid; do
  [[ -n "$rid" ]] || continue
  if ! az rest --method DELETE --uri "$GRAPH/roleManagement/directory/roleAssignments/$rid" >/dev/null 2>&1; then
    step "Removed Directory Readers (PIM active) via schedule request" \
      az rest --method POST --uri "$GRAPH/roleManagement/directory/roleAssignmentScheduleRequests" \
      --headers "Content-Type=application/json" --body "$REMOVE_BODY"
  else
    echo ">> Removed Directory Readers (standard assignment $rid)"
  fi
done < "$TMP/dir_std.txt"
if [[ "${DIR_ACTIVE:-0}" != "0" && ! -s "$TMP/dir_std.txt" ]]; then
  step "Removed Directory Readers (PIM active)" \
    az rest --method POST --uri "$GRAPH/roleManagement/directory/roleAssignmentScheduleRequests" \
    --headers "Content-Type=application/json" --body "$REMOVE_BODY"
fi
if [[ "${DIR_ELIGIBLE:-0}" != "0" ]]; then
  step "Removed Directory Readers (PIM eligible)" \
    az rest --method POST --uri "$GRAPH/roleManagement/directory/roleEligibilityScheduleRequests" \
    --headers "Content-Type=application/json" --body "$REMOVE_BODY"
fi

# 4. Client secret(s) - only needed when keeping the app
if [[ "$KEEP_APP" == "true" ]]; then
  for kid in $SECRET_IDS; do
    step "Removed client secret $kid" az ad app credential delete --id "$APP_ID" --key-id "$kid"
  done
fi

# 5. Service principal and app registration
if [[ "$KEEP_APP" != "true" ]]; then
  if [[ -n "$SP_OBJECT_ID" ]]; then
    step "Deleted service principal $SP_OBJECT_ID" az ad sp delete --id "$SP_OBJECT_ID"
  fi
  step "Deleted app registration $APP_DISPLAY ($APP_ID)" az ad app delete --id "$APP_ID"
  # Verify, and retry once by object ID if the app is still there
  if az ad app show --id "$APP_ID" >/dev/null 2>&1; then
    step "Retry: deleted app registration by object ID $APP_OBJECT_ID" az ad app delete --id "$APP_OBJECT_ID"
  fi
  if az ad app show --id "$APP_ID" >/dev/null 2>&1; then
    echo "!! App registration $APP_DISPLAY ($APP_ID) STILL EXISTS."
    echo "   Deleting it needs Application Administrator / Cloud Application Administrator, or being an owner of the app."
    echo "   Check the error above; you can also delete it in Entra admin center > App registrations."
  else
    echo ">> Verified: app registration $APP_ID no longer exists."
    echo "   (Deleted app registrations stay in Entra 'Deleted applications' for 30 days and can be restored there.)"
  fi
fi

echo
echo "Teardown finished. Remember to remove the integration in the FortiCNAPP console if it still exists."
}

# ======================================================================================
# Directory Readers through PIM
# ======================================================================================
fn_pim() {
APP_ID="${APP_ID:-}"
APP_NAME="${APP_NAME:-}"
ASSIGNMENT_TYPE="${ASSIGNMENT_TYPE:-active}"
DURATION="${DURATION:-}"
JUSTIFICATION="${JUSTIFICATION:-FortiCNAPP Azure integration - read directory metadata}"
ROLE_TEMPLATE_ID="88d8e3e3-8f55-4a1e-953a-9b9898b8876b"   # Directory Readers


# Ask for the app if it was not supplied via APP_ID / APP_NAME (accepts a name or a client ID)
if [[ -z "$APP_ID" && -z "$APP_NAME" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "App registration name or Application (client) ID: " APP_INPUT
    [[ -n "$APP_INPUT" ]] || { echo "No app provided."; exit 1; }
    if [[ "$APP_INPUT" =~ $GUID_RE ]]; then APP_ID="$APP_INPUT"; else APP_NAME="$APP_INPUT"; fi
  else
    echo "Set APP_ID or APP_NAME (no interactive terminal to prompt on)."; exit 1
  fi
fi

# Resolve the app and its service principal
if [[ -z "$APP_ID" ]]; then
  MATCHES=$(az ad app list --display-name "$APP_NAME" --query "[].appId" -o tsv)
  COUNT=$(printf '%s\n' "$MATCHES" | grep -c . || true)
  if [[ "$COUNT" -eq 0 ]]; then echo "App '$APP_NAME' not found."; exit 1; fi
  if [[ "$COUNT" -gt 1 ]]; then
    echo "Multiple apps named '$APP_NAME' - re-run with APP_ID set to one of:"
    printf '  %s\n' $MATCHES; exit 1
  fi
  APP_ID="$MATCHES"
fi
APP_DISPLAY=$(az ad app show --id "$APP_ID" --query displayName -o tsv)
echo ">> Using app: $APP_DISPLAY ($APP_ID)"
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
echo ">> App: $APP_ID  SP object: $SP_OBJECT_ID"

# Schedule: permanent unless DURATION is set
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -z "$DURATION" ]]; then
  EXPIRATION='{"type":"noExpiration"}'
else
  EXPIRATION="{\"type\":\"afterDuration\",\"duration\":\"$DURATION\"}"
fi

case "$ASSIGNMENT_TYPE" in
  active)   ENDPOINT="roleManagement/directory/roleAssignmentScheduleRequests" ;;
  eligible) ENDPOINT="roleManagement/directory/roleEligibilityScheduleRequests" ;;
  *) echo "ASSIGNMENT_TYPE must be active or eligible"; exit 1 ;;
esac

# Skip if the app already holds the role (active or eligible)
for kind in roleAssignments roleEligibilityScheduleInstances roleAssignmentScheduleInstances; do
  hit=$(az rest --method GET \
    --uri "$GRAPH/roleManagement/directory/$kind?\$filter=principalId eq '$SP_OBJECT_ID' and roleDefinitionId eq '$ROLE_TEMPLATE_ID'" \
    --query "length(value)" -o tsv 2>/dev/null || echo 0)
  if [[ "$hit" != "0" ]]; then
    echo ">> Directory Readers already present ($kind). Nothing to do."; exit 0
  fi
done

BODY="{\"action\":\"adminAssign\",\"principalId\":\"$SP_OBJECT_ID\",\"roleDefinitionId\":\"$ROLE_TEMPLATE_ID\",\"directoryScopeId\":\"/\",\"justification\":\"$JUSTIFICATION\",\"scheduleInfo\":{\"startDateTime\":\"$START\",\"expiration\":$EXPIRATION}}"

RESP=$(az rest --method POST --uri "$GRAPH/$ENDPOINT" \
  --headers "Content-Type=application/json" --body "$BODY" \
  --query "{id:id,status:status,action:action}" -o json)

echo "$RESP"
echo ">> Request submitted ($ASSIGNMENT_TYPE, ${DURATION:-permanent}). Entra notifies other admins by email."
echo "   If status is PendingApproval, an approver must act in PIM."
}

# ======================================================================================
# Main
# ======================================================================================
usage() {
  echo "Usage: $0 [onboard|check|delete|pim]"
  echo "  onboard  create/reuse the app and assign all prerequisites (+ optional temporary credentials)"
  echo "  check    pre-flight check that an app holds every required role (read-only)"
  echo "  delete   remove what onboarding created (roles, secret, service principal, app)"
  echo "  pim      assign Directory Readers through PIM"
}

ACTION="${1:-${ACTION:-}}"
case "$ACTION" in -h|--help|help) usage; exit 0 ;; esac

if ! az account show >/dev/null 2>&1; then
  echo "Not logged in to Azure. Run: az login"; exit 1
fi
ACCOUNT_USER=$(az account show --query user.name -o tsv)
ACCOUNT_TENANT=$(az account show --query tenantId -o tsv)
echo "Signed in as: $ACCOUNT_USER   Tenant: $ACCOUNT_TENANT"

if [[ -z "$ACTION" ]]; then
  [[ -t 0 ]] || { usage; echo "No interactive terminal: pass an action."; exit 1; }
  echo
  echo "What do you want to do?"
  echo "  1) Onboard  - create/reuse the app and assign all prerequisites"
  echo "  2) Check    - pre-flight: verify an app has every required role"
  echo "  3) Delete   - remove the app and what onboarding created"
  echo "  4) PIM      - assign Directory Readers through PIM (Active)"
  echo "  q) Quit"
  read -r -p "Choose [1-4/q]: " CHOICE
  case "$CHOICE" in
    1) ACTION=onboard ;; 2) ACTION=check ;; 3) ACTION=delete ;; 4) ACTION=pim ;;
    q|Q|"") echo "Nothing done."; exit 0 ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac
fi

case "$ACTION" in
  onboard) FN=fn_onboard ;;
  check)   FN=fn_check ;;
  delete)  FN=fn_delete ;;
  pim)     FN=fn_pim ;;
  *) echo "Unknown action: $ACTION"; usage; exit 1 ;;
esac

# Each action runs in its own subshell so its own 'exit' never skips cleanup
set +e
( set -euo pipefail; "$FN" )
RC=$?
exit "$RC"
