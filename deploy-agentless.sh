#!/usr/bin/env bash

################################################################################
# FortiCNAPP Azure Agentless Scanning Integration
# Terraform automation with credential validation + PLAN DEBUG / WATCHDOG
# Supports: Single and multi-region, single and multi-subscription
#
# Optional environment knobs (all have defaults):
#   DEBUG_LEVEL=DEBUG|TRACE|INFO   TF_LOG level used during plan   (default DEBUG)
#   HEARTBEAT_SECS=15              progress line interval           (default 15)
#   STALL_SECS=90                  no new activity => stall report  (default 90)
#   PLAN_TIMEOUT=1800              hard limit for plan, in seconds  (default 1800)
#   TF_PLAN_ARGS="-parallelism=3"  extra args passed to terraform plan
#   SKIP_PREFLIGHT=1               skip the pre-flight diagnostics
#   VERBOSE=0|1|2                  live Terraform log on screen during plan
#                                    0 = off (heartbeat only)
#                                    1 = key events (HTTP calls, auth, retries,
#                                        provider/resource activity, errors)
#                                    2 = FULL firehose (every TF_LOG line)
#                                  (if unset, you are asked at start)
#   VERBOSE_FILTER='regex'         override the filter used by VERBOSE=1
################################################################################

set -e

VERBOSE="${VERBOSE:-}"
VERBOSE_FILTER="${VERBOSE_FILTER:-HTTP|http\.|request|response|status|Status|auth|token|login|az |provider|plugin|Refreshing|Reading|Read complete|Still |lock|retry|Retry|timeout|error|ERROR|WARN|panic|AADSTS|throttl|429|lacework|azurerm}"
VERB_PID=""
# mawk (default awk on Debian/Ubuntu) block-buffers piped input; force line mode so live streaming works
AWK_STREAM=(awk)
if awk -W version 2>&1 | grep -qi mawk; then
    AWK_STREAM=(awk -W interactive)
fi
DEBUG_LEVEL="${DEBUG_LEVEL:-DEBUG}"
HEARTBEAT_SECS="${HEARTBEAT_SECS:-15}"
STALL_SECS="${STALL_SECS:-90}"
PLAN_TIMEOUT="${PLAN_TIMEOUT:-1800}"

PLAN_PID=""
TAIL_PID=""
PLAN_OUT=""
PLAN_TFLOG=""
PLAN_START=0

echo
echo "=============================================="
echo " FortiCNAPP Azure Agentless Integration"
echo " Credential validation + Plan debug watchdog"
echo "=============================================="
echo

# ------------------------------------------------
# Collect information
# ------------------------------------------------

read -rp "FortiCNAPP account (e.g., 'myaccount'): " LW_ACCOUNT
# Normalize: accept 'myaccount', 'myaccount.lacework.net' or 'https://myaccount.lacework.net/'
LW_ACCOUNT="${LW_ACCOUNT#http://}"
LW_ACCOUNT="${LW_ACCOUNT#https://}"
LW_ACCOUNT="${LW_ACCOUNT%%/*}"
LW_ACCOUNT="${LW_ACCOUNT%.lacework.net}"
read -rp "FortiCNAPP API key: " LW_API_KEY
read -rsp "FortiCNAPP API secret: " LW_API_SECRET
echo

read -rp "Azure Tenant ID: " AZ_TENANT_ID
read -rp "Azure Subscription ID: " AZ_SUBSCRIPTION_ID
read -rp "Azure region [canadacentral]: " AZ_REGION
AZ_REGION=${AZ_REGION:-canadacentral}

read -rp "Scanning Resource Group [MYRGFORTICNAPP]: " RG_NAME
RG_NAME=${RG_NAME:-MYRGFORTICNAPP}

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

read -rp "Enable Terraform plan debug (TF_LOG + stall watchdog)? [Y/n]: " DBG
if [[ "$DBG" =~ ^[Nn]$ ]]; then
    DEBUG_ON=0
    VERBOSE=0
else
    DEBUG_ON=1
    if [[ -z "$VERBOSE" ]]; then
        echo
        echo "Verbose plan output (live Terraform log on screen):"
        echo "  0 = off     (heartbeat only)"
        echo "  1 = key events (HTTP calls, auth, retries, resource activity, errors)"
        echo "  2 = full firehose (every TF_LOG line)"
        read -rp "Verbose level [1]: " VERBOSE
        VERBOSE=${VERBOSE:-1}
    fi
fi
case "$VERBOSE" in 0|1|2) ;; *) VERBOSE=1 ;; esac

# ------------------------------------------------
# Create working directory
# ------------------------------------------------

WORKDIR="$HOME/tf_forticnapp_agentless"
DEBUG_DIR="$WORKDIR/debug"

mkdir -p "$WORKDIR" "$DEBUG_DIR"
cd "$WORKDIR"

echo
echo "Working directory:"
pwd
echo

# ------------------------------------------------
# Debug / diagnostic helper functions
# ------------------------------------------------

fmt_time() { printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# Run a command with a time limit (portable: no GNU 'timeout' needed, works on macOS)
run_with_timeout() {
    local secs=$1; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
    local wd=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
    return $rc
}

# Remove secrets / tokens from anything we print or save.
# Single awk process with fflush() so it is safe for LIVE streaming (verbose mode).
sanitize() {
    LWS="$LW_API_SECRET" LWK="$LW_API_KEY" "${AWK_STREAM[@]}" '
        function redact_lit(line, lit,    i) {
            while (length(lit) > 0 && (i = index(line, lit)) > 0)
                line = substr(line, 1, i - 1) "***REDACTED***" substr(line, i + length(lit))
            return line
        }
        function redact_kv(line,    out, m, pre, st, ln) {
            out = ""
            while (match(line, /(access_token|refresh_token|id_token|client_secret|X-LW-UAKS|Authorization)["=: ]+[^", &]+/)) {
                st = RSTART; ln = RLENGTH
                m = substr(line, st, ln)
                match(m, /^[A-Za-z_-]+["=: ]+/)
                pre = substr(m, 1, RLENGTH)
                out = out substr(line, 1, st - 1) pre "***REDACTED***"
                line = substr(line, st + ln)
            }
            return out line
        }
        BEGIN { s = ENVIRON["LWS"]; k = ENVIRON["LWK"] }
        {
            line = $0
            line = redact_lit(line, s)
            line = redact_lit(line, k)
            gsub(/[Bb]earer [A-Za-z0-9._~+\/=-]+/, "Bearer ***REDACTED***", line)
            line = redact_kv(line)
            print line
            fflush()
        }'
}

# Live-stream the Terraform debug log to the screen (sanitized, optionally filtered)
start_verbose() {
    [[ "$DEBUG_ON" == "1" && "$VERBOSE" != "0" ]] || return 0
    echo "Verbose: level $VERBOSE — live Terraform log below (prefixed [tf]; secrets redacted)"
    if [[ "$VERBOSE" == "1" ]]; then
        echo "         filtered to key events; use VERBOSE=2 for every line"
    fi
    (
        if [[ "$VERBOSE" == "2" ]]; then
            tail -n +1 -f "$PLAN_TFLOG" 2>/dev/null | sanitize | "${AWK_STREAM[@]}" '{ print "[tf] " substr($0, 1, 260); fflush() }'
        else
            tail -n +1 -f "$PLAN_TFLOG" 2>/dev/null | sanitize | grep --line-buffered -E "$VERBOSE_FILTER" | "${AWK_STREAM[@]}" '{ print "[tf] " substr($0, 1, 260); fflush() }'
        fi
    ) &
    VERB_PID=$!
}

stop_verbose() {
    if [[ -n "$VERB_PID" ]]; then
        pkill -P "$VERB_PID" 2>/dev/null || true
        kill "$VERB_PID" 2>/dev/null || true
        wait "$VERB_PID" 2>/dev/null || true
        VERB_PID=""
    fi
}

check_url() {   # check_url "label" "url"
    local code t=$SECONDS
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$2" 2>/dev/null || true)
    if [[ -z "$code" || "$code" == "000" ]]; then
        echo "✗ $1: UNREACHABLE ($2)"
    else
        echo "✓ $1: reachable (HTTP $code, $((SECONDS - t))s)"
    fi
}

preflight_checks() {
    echo "=============================================="
    echo " Pre-flight diagnostics (finds common causes of a stuck plan)"
    echo "=============================================="

    # 1) Can the az CLI issue a token? (this is exactly what the azurerm provider does)
    local t0=$SECONDS
    if run_with_timeout 45 az account get-access-token --subscription "$AZ_SUBSCRIPTION_ID" -o none >/dev/null 2>&1; then
        echo "✓ Azure token issued by az CLI ($((SECONDS - t0))s)"
    else
        echo "✗ az CLI could NOT issue a token within 45s  <-- #1 cause of a hanging plan"
        echo "    (expired token / MFA / conditional access prompt)"
        echo "    Fix: az login --tenant $AZ_TENANT_ID   then re-run"
    fi

    # 2) Network reachability of every endpoint terraform will touch
    check_url "Terraform registry   " "https://registry.terraform.io/.well-known/terraform.json"
    check_url "HashiCorp releases   " "https://releases.hashicorp.com/"
    check_url "GitHub (module src)  " "https://github.com"
    check_url "Azure Resource Mgr   " "https://management.azure.com/"
    check_url "Azure AD login       " "https://login.microsoftonline.com/${AZ_TENANT_ID}/v2.0/.well-known/openid-configuration"
    check_url "FortiCNAPP API       " "https://${LW_ACCOUNT}.lacework.net/"

    # 3) Resource provider registration state (azurerm may try to register them and appear stuck)
    local rp st
    for rp in Microsoft.Compute Microsoft.Storage Microsoft.Network Microsoft.OperationalInsights Microsoft.ManagedIdentity Microsoft.Authorization; do
        st=$(run_with_timeout 20 az provider show -n "$rp" --query registrationState -o tsv 2>/dev/null || true)
        if [[ "$st" == "Registered" ]]; then
            echo "✓ Resource provider $rp: Registered"
        else
            echo "⚠ Resource provider $rp: '${st:-unknown}'  (azurerm may spend minutes registering it)"
        fi
    done

    # 4) Microsoft Graph token (needed by the azuread provider used by the agentless module).
    #    This is a DIFFERENT token from the Azure Resource Manager one tested above.
    t0=$SECONDS
    if run_with_timeout 45 az account get-access-token --resource-type ms-graph -o none >/dev/null 2>&1; then
        echo "✓ Microsoft Graph token issued by az CLI ($((SECONDS - t0))s)"
    else
        echo "✗ az CLI could NOT issue a Microsoft Graph token  <-- causes the azuread 'unable to obtain access token' error"
        echo "    Fix: az logout; az login --tenant $AZ_TENANT_ID --allow-no-subscriptions"
        echo "         (if it persists: az login --tenant $AZ_TENANT_ID --scope https://graph.microsoft.com//.default)"
        echo "    Also check Conditional Access / MFA policy for Graph, and that your account can"
        echo "    create app registrations (Application Administrator or equivalent role)."
    fi

    # 5) FortiCNAPP credentials are passed to the provider explicitly (no ~/.lacework.toml needed)
    echo "✓ Lacework provider will use explicit credentials for account '${LW_ACCOUNT}'"

    # 6) Competing terraform processes / stale lock
    if pgrep -fl 'terraform (plan|apply|init)' >/dev/null 2>&1; then
        echo "⚠ Another terraform process is running:"
        pgrep -fl 'terraform (plan|apply|init)' | sed 's/^/    /'
    else
        echo "✓ No other terraform plan/apply/init running"
    fi
    if [[ -f "$WORKDIR/.terraform.tfstate.lock.info" ]]; then
        echo "⚠ Stale state lock file present: $WORKDIR/.terraform.tfstate.lock.info"
    fi

    # 7) Proxy settings (credentials stripped)
    local v
    for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
        if [[ -n "${!v:-}" ]]; then
            echo "ℹ $v=$(echo "${!v}" | sed -E 's#//[^@/]*@#//***@#')"
        fi
    done
    echo
}

# Pattern::explanation rules applied to the captured logs
analyze_log() {
    local found=0 r pat msg
    local -a rules=(
        "azuread.*requires explicit configuration|building client: unable to obtain access token|running Azure CLI: exit status::azuread provider could not get a Microsoft Graph token from az CLI. Run: az logout; az login --tenant $AZ_TENANT_ID --allow-no-subscriptions (or add --scope https://graph.microsoft.com//.default) and check Conditional Access / app-registration rights."
        "Unable to create Lacework API client|Lacework provider is not configured properly::Lacework provider is missing account/api_key/api_secret. Check the FortiCNAPP account name (no .lacework.net), API key and secret."
        "device code|To sign in, use a web browser|AADSTS|interaction_required|Please run 'az login'::Azure auth wants an interactive login / MFA. Run: az login --tenant $AZ_TENANT_ID and retry."
        "status[= :]+429|HTTP/[0-9.]+ 429|TooManyRequests|throttl::API throttling. Retry later or lower concurrency: TF_PLAN_ARGS=\"-parallelism=3\"."
        "i/o timeout|dial tcp|TLS handshake timeout|connection reset|no such host|proxyconnect::Network/DNS/proxy problem. Check VPN/proxy/firewall for management.azure.com, login.microsoftonline.com and ${LW_ACCOUNT}.lacework.net."
        "status[= :]+40[13]|HTTP/[0-9.]+ 40[13]|Unauthorized|AuthorizationFailed|AuthenticationFailed|invalid_client::Credential or permission problem (Azure RBAC or FortiCNAPP key). Verify roles on subscription $AZ_SUBSCRIPTION_ID and the API key/secret."
        "MissingSubscriptionRegistration|MissingRegistrationForResourceProvider|Registering resource provider|resource provider::Azure resource provider registration. Register them yourself (az provider register -n Microsoft.X) or skip auto-registration in the azurerm provider."
        "Error acquiring the state lock|Acquiring state lock::State lock held by another terraform process. Check: ps aux | grep terraform ; remove stale .terraform.tfstate.lock.info."
        "unable to load profile|could not find profile|profile .* not found|lacework.*toml::Lacework provider cannot load its profile. Make sure ~/.lacework.toml contains [forticnapp]."
        "will retry|Retrying|retrying::A provider is retrying a failing API call. See the last debug lines for the failing endpoint."
    )
    for r in "${rules[@]}"; do
        pat="${r%%::*}"
        msg="${r#*::}"
        if grep -qiE "$pat" "$@" 2>/dev/null; then
            echo "  ⚠ $msg"
            found=1
        fi
    done
    if [[ $found -eq 0 ]]; then
        echo "  (no known pattern matched — review the last debug lines and the bundle in $DEBUG_DIR)"
    fi
}

stall_report() {
    local reason="$1" plist pids
    echo
    echo "!! ----------------------------------------------------------------"
    echo "!! $reason"
    echo "!! Elapsed: $(fmt_time $((SECONDS - PLAN_START)))"
    echo "!! ----------------------------------------------------------------"

    echo "--- Last terraform output ---"
    tail -n 8 "$PLAN_OUT" 2>/dev/null | cut -c1-200 | sed 's/^/   /'

    local slow
    slow=$(grep -E 'Still (reading|refreshing|creating|modifying)' "$PLAN_OUT" 2>/dev/null | tail -n 3 || true)
    if [[ -n "$slow" ]]; then
        echo "--- Resources terraform is waiting on ---"
        echo "$slow" | cut -c1-200 | sed 's/^/   /'
    fi

    if ! grep -qE 'Refreshing state|Read complete|Reading' "$PLAN_OUT" 2>/dev/null; then
        echo "--- Diagnosis ---"
        echo "   ⚠ No resource has started refreshing yet: terraform is blocked BEFORE its first resource call."
        echo "     Likely: azurerm auth (az CLI token / MFA), Lacework profile load, state lock, or provider download."
    fi

    if [[ "$DEBUG_ON" == "1" && -s "$PLAN_TFLOG" ]]; then
        echo "--- Last debug log lines (sanitized) ---"
        tail -n 12 "$PLAN_TFLOG" | cut -c1-220 | sanitize | sed 's/^/   /'
    fi

    echo "--- Processes ---"
    pids="$PLAN_PID $(pgrep -P "$PLAN_PID" 2>/dev/null | tr '\n' ' ')"
    plist=$(echo $pids | tr ' ' ',')
    ps -o pid=,etime=,pcpu=,command= -p "$plist" 2>/dev/null | cut -c1-170 | sed 's/^/   /' || true
    pgrep -fl 'az (account|login)' 2>/dev/null | cut -c1-170 | sed 's/^/   (az) /' || true
    if command -v lsof >/dev/null 2>&1; then
        echo "--- Network sockets (SYN_SENT = cannot connect, ESTABLISHED = waiting on remote) ---"
        lsof -nP -a -p "$plist" -iTCP 2>/dev/null | awk 'NR==1 || /ESTABLISHED|SYN_SENT|CLOSE_WAIT/' | cut -c1-170 | sed 's/^/   /' || true
    fi

    echo "--- Suspected causes ---"
    if [[ "$DEBUG_ON" == "1" ]]; then
        analyze_log "$PLAN_OUT" "$PLAN_TFLOG"
    else
        analyze_log "$PLAN_OUT"
    fi
    echo "!! ----------------------------------------------------------------"
    echo
}

stop_plan() {
    if [[ -z "$PLAN_PID" ]]; then
        return 0
    fi
    kill -INT "$PLAN_PID" 2>/dev/null || true       # graceful: lets terraform release locks
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$PLAN_PID" 2>/dev/null || break
        sleep 2
    done
    if kill -0 "$PLAN_PID" 2>/dev/null; then
        pkill -KILL -P "$PLAN_PID" 2>/dev/null || true
        kill -KILL "$PLAN_PID" 2>/dev/null || true
    fi
}

finalize_debug() {
    # Sanitize stdout log
    if [[ -s "$PLAN_OUT" ]]; then
        sanitize < "$PLAN_OUT" > "$PLAN_OUT.tmp" && mv "$PLAN_OUT.tmp" "$PLAN_OUT"
    fi
    if [[ "$DEBUG_ON" != "1" ]]; then
        return 0
    fi

    # Sanitize the raw TF_LOG file, then delete the raw one (it can contain tokens)
    if [[ -s "$PLAN_TFLOG" ]]; then
        sanitize < "$PLAN_TFLOG" > "$DEBUG_DIR/terraform_debug.log"
    fi
    rm -f "$PLAN_TFLOG"

    {
        echo "Date:       $(date)"
        echo "Host:       $(uname -a)"
        echo "Terraform:  $(terraform version 2>/dev/null | tr '\n' ' ')"
        echo "Azure CLI:  $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
        echo "Tenant:     $AZ_TENANT_ID"
        echo "Subscr.:    $AZ_SUBSCRIPTION_ID"
        echo "Region:     $AZ_REGION"
        echo "Log level:  $DEBUG_LEVEL"
        local v
        for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
            if [[ -n "${!v:-}" ]]; then
                echo "$v=$(echo "${!v}" | sed -E 's#//[^@/]*@#//***@#')"
            fi
        done
    } > "$DEBUG_DIR/env_info.txt" 2>&1

    {
        echo "Suspected causes:"
        analyze_log "$PLAN_OUT" "$DEBUG_DIR/terraform_debug.log"
    } > "$DEBUG_DIR/analysis.txt" 2>&1

    echo
    echo "Debug bundle (secrets redacted): $DEBUG_DIR"
    echo "  plan_stdout.log, terraform_debug.log, env_info.txt, analysis.txt"
}

on_interrupt() {
    echo
    echo "Interrupted — stopping terraform..."
    stop_plan
    stop_verbose
    if [[ -n "$TAIL_PID" ]]; then kill "$TAIL_PID" 2>/dev/null || true; fi
    if [[ -n "$PLAN_OUT" ]]; then finalize_debug || true; fi
    exit 130
}
trap on_interrupt INT TERM

# Runs 'terraform plan' in the background with heartbeat, stall detection and hard timeout
run_plan() {
    PLAN_OUT="$DEBUG_DIR/plan_stdout.log"
    PLAN_TFLOG="$DEBUG_DIR/terraform_debug.raw.log"
    : > "$PLAN_OUT"
    : > "$PLAN_TFLOG"

    local mon="$PLAN_OUT"
    local -a envs=()
    if [[ "$DEBUG_ON" == "1" ]]; then
        envs=(TF_LOG="$DEBUG_LEVEL" TF_LOG_PATH="$PLAN_TFLOG")
        mon="$PLAN_TFLOG"
    fi

    local -a cmd=(terraform plan -input=false -no-color -lock-timeout=120s -out=tfplan)
    if [[ -n "${TF_PLAN_ARGS:-}" ]]; then
        # shellcheck disable=SC2206
        cmd+=($TF_PLAN_ARGS)
    fi

    echo "Running: ${cmd[*]}"
    if [[ "$DEBUG_ON" == "1" ]]; then
        echo "Debug:   TF_LOG=$DEBUG_LEVEL verbose=$VERBOSE (heartbeat ${HEARTBEAT_SECS}s, stall alert ${STALL_SECS}s, hard timeout ${PLAN_TIMEOUT}s)"
    fi
    echo

    PLAN_START=$SECONDS
    env "${envs[@]}" "${cmd[@]}" > "$PLAN_OUT" 2>&1 &
    PLAN_PID=$!
    tail -n +1 -f "$PLAN_OUT" &
    TAIL_PID=$!
    start_verbose

    local last_size=-1 last_change=$SECONDS last_hb=$SECONDS now size refreshed lastline slow timed_out=0

    while kill -0 "$PLAN_PID" 2>/dev/null; do
        sleep 2
        now=$SECONDS
        size=$(wc -c < "$mon" 2>/dev/null | tr -d ' ')

        if [[ "$size" != "$last_size" ]]; then
            last_size=$size
            last_change=$now
        fi

        # Heartbeat
        if (( now - last_hb >= HEARTBEAT_SECS )); then
            last_hb=$now
            refreshed=$(grep -cE 'Refreshing state|Read complete' "$PLAN_OUT" 2>/dev/null || true)
            lastline=$(tail -n 1 "$PLAN_OUT" 2>/dev/null | cut -c1-100)
            slow=$(grep -E 'Still (reading|refreshing|creating|modifying)' "$PLAN_OUT" 2>/dev/null | tail -n 1 | cut -c1-100 || true)
            echo "  ⏱  $(fmt_time $((now - PLAN_START))) | log $((size / 1024))KB | refresh/read events: ${refreshed:-0} | last: ${slow:-$lastline}"
        fi

        # Stall detection (no new log/output activity)
        if (( now - last_change >= STALL_SECS )); then
            stall_report "STALL: no new activity for $((now - last_change))s — terraform appears stuck"
            last_change=$now     # report again only after another STALL_SECS
        fi

        # Hard timeout
        if (( now - PLAN_START >= PLAN_TIMEOUT )); then
            timed_out=1
            stall_report "TIMEOUT: plan exceeded ${PLAN_TIMEOUT}s — stopping terraform"
            stop_plan
            break
        fi
    done

    local rc=0
    wait "$PLAN_PID" 2>/dev/null || rc=$?
    sleep 1
    stop_verbose
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$TAIL_PID" 2>/dev/null || true
    PLAN_PID=""
    TAIL_PID=""

    if [[ $timed_out -eq 1 ]]; then
        rc=124
    fi

    if [[ $rc -ne 0 ]]; then
        echo
        echo "--- Failure analysis ---"
        analyze_log "$PLAN_OUT" "$PLAN_TFLOG"
    fi

    finalize_debug
    return $rc
}

# ------------------------------------------------
# Check prerequisites
# ------------------------------------------------

echo "Checking prerequisites..."

command -v terraform >/dev/null 2>&1 || {
    echo "ERROR: terraform is not installed."
    echo "Install from: https://www.terraform.io/downloads"
    exit 1
}

command -v az >/dev/null 2>&1 || {
    echo "ERROR: Azure CLI (az) is not installed."
    echo "Install from: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
}

echo "✓ Terraform: OK ($(terraform version | head -n 1))"
echo "✓ Azure CLI: OK"

# ------------------------------------------------
# Validate Azure CLI login & subscription
# ------------------------------------------------

echo
echo "Validating Azure authentication..."

if ! az account show >/dev/null 2>&1; then
    echo "⚠ Azure CLI is not logged in. Starting login flow..."
    az login --tenant "$AZ_TENANT_ID"
else
    CURRENT_TENANT=$(az account show --query tenantId -o tsv)
    if [[ "$CURRENT_TENANT" != "$AZ_TENANT_ID" ]]; then
        echo "⚠ Current tenant ($CURRENT_TENANT) differs from target ($AZ_TENANT_ID)"
        echo "  Re-authenticating to target tenant..."
        az logout 2>/dev/null || true
        az login --tenant "$AZ_TENANT_ID"
    fi
fi

echo
echo "Setting Azure subscription to $AZ_SUBSCRIPTION_ID..."

if ! az account set --subscription "$AZ_SUBSCRIPTION_ID" 2>/dev/null; then
    echo "ERROR: Failed to set subscription $AZ_SUBSCRIPTION_ID"
    echo ""
    echo "Available subscriptions:"
    az account list --output table
    exit 1
fi

echo
echo "✓ Azure authentication confirmed:"
az account show \
    --query "{subscription:name, subscriptionId:id, tenantId:tenantId}" \
    -o table

# ------------------------------------------------
# Test Lacework credentials
# ------------------------------------------------

echo
echo "Testing Lacework API credentials..."

LACEWORK_PROFILE="forticnapp"
LACEWORK_API_URL="https://${LW_ACCOUNT}.lacework.net"

# Secret is passed via stdin header (not visible in the process list); 20s max so it can never hang
RESPONSE=$(printf 'X-LW-UAKS: %s\n' "$LW_API_SECRET" | curl -s --max-time 20 -X POST "${LACEWORK_API_URL}/api/v2/access/tokens" \
  -H @- \
  -H "Content-Type: application/json" \
  -d '{"keyId":"'"${LW_API_KEY}"'","expiryTime":3600}' \
  2>&1 || true)

if echo "$RESPONSE" | grep -q "access_token"; then
    echo "✓ Lacework API: OK"
else
    echo "⚠ Could not validate Lacework credentials via API"
    echo "  Response: $(echo "$RESPONSE" | head -c 150)"
    echo "  Proceeding — Terraform will catch credential errors during init"
fi

# ------------------------------------------------
# Create Terraform configuration files
# ------------------------------------------------

echo
echo "Creating Terraform configuration..."

# version.tf
cat > version.tf <<'TFEOF'
terraform {
  required_version = ">= 1.3"

  required_providers {
    lacework = {
      source  = "lacework/lacework"
      version = "~> 2.6"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0, < 5.0"
    }
    azuread = {
      source = "hashicorp/azuread"
    }
  }
}
TFEOF

# variables.tf
cat > variables.tf <<'TFEOF'
variable "lacework_account" {
  type        = string
  description = "FortiCNAPP/Lacework account name (e.g., 'myaccount' from myaccount.lacework.net)"
  sensitive   = true
}

variable "lacework_api_key" {
  type        = string
  description = "FortiCNAPP/Lacework API key"
  sensitive   = true
}

variable "lacework_api_secret" {
  type        = string
  description = "FortiCNAPP/Lacework API secret"
  sensitive   = true
}

variable "azure_subscription_id" {
  type        = string
  description = "Azure Subscription ID where agentless scanning will be deployed"
}

variable "azure_tenant_id" {
  type        = string
  description = "Azure Tenant ID"
}

variable "azure_region" {
  type        = string
  description = "Azure region for scanning resources"
  default     = "canadacentral"
}

variable "resource_group_name" {
  type        = string
  description = "Resource Group name for FortiCNAPP agentless scanning infrastructure"
  default     = "FFHAZCRGFORTICNAPP"
}

variable "integration_name" {
  type        = string
  description = "Lacework/FortiCNAPP integration name"
  default     = "az_forticnapp_agentless"
}

variable "tags" {
  type        = map(string)
  description = "Common tags for all resources"
  default = {
    managed_by  = "terraform"
    environment = "production"
    platform    = "forticnapp"
  }
}
TFEOF

# main.tf
cat > main.tf <<'TFEOF'
# Azure Provider Configuration
provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id
}

# Azure AD (Entra ID / Microsoft Graph) provider - used by the agentless module
# to create the app registration / service principal. Needs its own Graph token.
provider "azuread" {
  tenant_id = var.azure_tenant_id
}

# Lacework Provider Configuration
# Explicit credentials (no dependency on ~/.lacework.toml being found)
provider "lacework" {
  account    = var.lacework_account
  api_key    = var.lacework_api_key
  api_secret = var.lacework_api_secret
}

# FortiCNAPP/Lacework Agentless Scanning Module
module "lacework_azure_agentless" {
  source = "lacework/agentless-scanning/azure"

  integration_level              = "SUBSCRIPTION"
  lacework_integration_name      = var.integration_name
  global                         = true
  create_log_analytics_workspace = true
  region                         = var.azure_region

  scanning_resource_group_name   = var.resource_group_name
  tenant_id                      = var.azure_tenant_id

  included_subscriptions = [
    "/subscriptions/${var.azure_subscription_id}"
  ]

  tags = var.tags
}
TFEOF

# outputs.tf
cat > outputs.tf <<'TFEOF'
output "integration_guid" {
  value       = try(module.lacework_azure_agentless.integration_guid, null)
  description = "Lacework integration GUID"
}

output "resource_group_id" {
  value       = try(module.lacework_azure_agentless.resource_group_id, null)
  description = "Azure Resource Group ID for scanning infrastructure"
}

output "scanning_enabled" {
  value       = try(module.lacework_azure_agentless.scanning_enabled, null)
  description = "Agentless scanning enabled status"
}

output "tenant_id" {
  value       = var.azure_tenant_id
  description = "Azure Tenant ID"
}

output "subscription_id" {
  value       = var.azure_subscription_id
  description = "Azure Subscription ID"
}

output "region" {
  value       = var.azure_region
  description = "Azure region for scanning resources"
}
TFEOF

# terraform.tfvars (with Lacework credentials)
cat > terraform.tfvars <<TFEOF
lacework_account      = "$LW_ACCOUNT"
lacework_api_key      = "$LW_API_KEY"
lacework_api_secret   = "$LW_API_SECRET"
azure_subscription_id = "$AZ_SUBSCRIPTION_ID"
azure_tenant_id       = "$AZ_TENANT_ID"
azure_region          = "$AZ_REGION"
resource_group_name   = "$RG_NAME"
integration_name      = "$INTEGRATION_NAME"
TFEOF

chmod 600 terraform.tfvars  # Protect credentials file

# ------------------------------------------------
# Create .lacework.toml credentials file
# ------------------------------------------------

echo "Creating .lacework.toml with credentials..."

cat > .lacework.toml <<TOMLEOF
[forticnapp]
account = "$LW_ACCOUNT"
api_key = "$LW_API_KEY"
api_secret = "$LW_API_SECRET"
version = 2
TOMLEOF

chmod 600 .lacework.toml

# Optional: Export as environment variables for Terraform provider fallback
export TF_VAR_lacework_account="$LW_ACCOUNT"
export TF_VAR_lacework_api_key="$LW_API_KEY"
export TF_VAR_lacework_api_secret="$LW_API_SECRET"

# ------------------------------------------------
# Pre-flight diagnostics
# ------------------------------------------------

echo
if [[ "${SKIP_PREFLIGHT:-0}" != "1" ]]; then
    preflight_checks
fi

# ------------------------------------------------
# Initialize Terraform
# ------------------------------------------------

echo
echo "=============================================="
echo " Terraform Init"
echo "=============================================="

if ! terraform init -input=false; then
    echo "ERROR: terraform init failed"
    echo "Common issues:"
    echo "  1. Network connectivity (check proxy settings)"
    echo "  2. Terraform registry unreachable"
    exit 1
fi

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

if ! terraform validate; then
    echo "ERROR: Terraform configuration is invalid"
    exit 1
fi

# ------------------------------------------------
# Plan (with debug watchdog)
# ------------------------------------------------

echo
echo "=============================================="
echo " Terraform Plan"
echo "=============================================="

if ! run_plan; then
    echo ""
    echo "ERROR: Terraform plan failed or was stopped"
    echo ""
    echo "Troubleshooting:"
    echo "  • Lacework creds → Verify account name / API key / secret (passed explicitly via terraform.tfvars)"
    echo "  • Azure auth → Run: az logout; az login --tenant $AZ_TENANT_ID --allow-no-subscriptions"
    echo "  • Graph token → az account get-access-token --resource-type ms-graph (must succeed for azuread)"
    echo "  • Permissions → Check IAM roles on subscription $AZ_SUBSCRIPTION_ID"
    echo "  • Debug bundle → $DEBUG_DIR (share these files; secrets are redacted)"
    echo "  • Retry slower/safer → TF_PLAN_ARGS=\"-parallelism=3\" or DEBUG_LEVEL=TRACE"
    echo ""
    exit 1
fi

# ------------------------------------------------
# Apply
# ------------------------------------------------

echo
echo "=============================================="
echo " Ready to deploy"
echo "=============================================="
echo
echo "✓ Terraform plan completed successfully in $(fmt_time $((SECONDS - PLAN_START)))."
echo "Review the plan above before proceeding."
echo

read -rp "Apply FortiCNAPP Agentless integration? [y/N]: " APPLY

if [[ ! "$APPLY" =~ ^[Yy]$ ]]; then
    echo
    echo "Plan completed. Nothing deployed."
    echo "Terraform plan saved to: $WORKDIR/tfplan"
    exit 0
fi

echo
echo "=============================================="
echo " Terraform Apply"
echo "=============================================="

if ! terraform apply -input=false tfplan; then
    echo "ERROR: Terraform apply failed"
    exit 1
fi

# ------------------------------------------------
# Post-deployment verification
# ------------------------------------------------

echo
echo "=============================================="
echo " FortiCNAPP Agentless Integration Complete ✓"
echo "=============================================="
echo

echo "Deployment outputs:"
terraform output -json | jq '.'

echo
echo "Next steps:"
echo "  1. Log in to FortiCNAPP console"
echo "  2. Navigate to Settings → Cloud Accounts"
echo "  3. Verify Azure integration appears as '$INTEGRATION_NAME'"
echo "  4. Monitor agentless scans starting in dashboard"
echo "  5. Review Azure Resource Group: $RG_NAME"
echo
echo "Working directory: $WORKDIR"
echo "Terraform state:   $WORKDIR/terraform.tfstate"
echo "Configuration:     $WORKDIR/terraform.tfvars"
echo

# ------------------------------------------------
# Cleanup sensitive data (optional)
# ------------------------------------------------

read -rp "Securely delete .lacework.toml? [y/N]: " CLEANUP

if [[ "$CLEANUP" =~ ^[Yy]$ ]]; then
    shred -vfz -n 3 .lacework.toml 2>/dev/null || rm -f .lacework.toml
    echo "✓ Credentials file deleted"
fi

echo
echo "Done."
