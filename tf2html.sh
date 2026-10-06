#!/usr/bin/env bash
# Usage: ./tf2html.sh                      export state with terraform, then report
#        ./tf2html.sh tfstate.json [out]   report from an existing file, no terraform
set -euo pipefail
STATE=${1:-tfstate.json}; OUT=${2:-azure_resources.html}

# With a file argument: use it as-is (terraform is never run).
# Without one: export the state with `terraform show -json` into tfstate.json.
if [ -n "${1:-}" ]; then
  [ -e "$STATE" ] || { echo "File not found: $STATE" >&2; exit 1; }
  [ -s "$STATE" ] || { echo "File is empty (0 bytes): $STATE. Regenerate it in your Terraform directory with: terraform show -json > $STATE" >&2; exit 1; }
else
  command -v terraform >/dev/null || { echo "terraform not found; pass a tfstate.json file instead" >&2; exit 1; }
  if ! terraform show -json > "$STATE.tmp" 2>/dev/null; then
    echo "terraform show failed, running terraform init..." >&2
    terraform init -input=false >/dev/null
    terraform show -json > "$STATE.tmp"
  fi
  mv "$STATE.tmp" "$STATE"
fi

ROWS='
{"azapi_resource":"Container App Job","azurerm_container_app_environment":"Container Apps Environment",
 "azurerm_storage_account":"Storage Account","azurerm_key_vault":"Key Vault","azurerm_user_assigned_identity":"Managed Identity",
 "azurerm_role_assignment":"RBAC Assignment","azurerm_role_definition":"RBAC Role Definition",
 "azurerm_virtual_network":"Virtual Network","azurerm_network_security_group":"Network Security Group",
 "azurerm_log_analytics_workspace":"Log Analytics Workspace","azurerm_nat_gateway":"NAT Gateway",
 "azuread_application":"Entra App Registration","azuread_service_principal":"Entra Service Principal"} as $names
| [ .values.root_module | .. | objects | select(has("resources")) | .resources[]
    | select(.mode=="managed" and (.type | test("^(azurerm|azuread)_|^azapi_resource$")))
    | .type as $t | .values as $v
    | [ $t + ".x",
        ($names[$t] // ($t | sub("^azure[a-z]+_"; "") | gsub("_"; " "))),
        (if $t == "azurerm_role_assignment" then "— (" + $v.role_definition_name + ")"
         else (($v.name // $v.display_name // "") | if . == "" then "—" else . end) end),
        (if $t | test("^azuread_|^azurerm_role_") then "—"
         else $v.resource_group_name // ($v.parent_id // "" | capture("resourceGroups/(?<r>[^/]+)").r?) // "—" end),
        (if $t == "azurerm_role_assignment" then (if $v.scope | test("^/subscriptions/[^/]+$") then "Subscription" else "Resource scope" end)
         elif $t == "azurerm_role_definition" then "Subscription"
         elif $t | startswith("azuread_") then "Global"
         else $v.location // "(parent)" end) ] ]
  | sort_by(.[0])'

# Terminal table
{ echo -e "Terraform resource\tAzure resource type\tResource name\tResource group\tRegion"
  jq -r "$ROWS | .[] | @tsv" "$STATE"; } | { column -t -s $'\t' 2>/dev/null || cat; }

# HTML report
COUNT=$(jq -r "$ROWS | length" "$STATE")
SUB=$(jq -r '[.. | objects | select(.type? == "azurerm_subscription") | .values.display_name] | .[0] // "—"' "$STATE")
RG=$(jq -r '[.. | objects | select(.type? == "azurerm_resource_group") | .values.name] | .[0] // "—"' "$STATE")
REGION=$(jq -r '[.. | objects | select(.type? == "azurerm_resource_group") | .values.location] | .[0] // "—"' "$STATE")

{ cat <<HTML
<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Azure resource inventory</title>
<style>
:root{--bg:#f5f7fa;--card:#fff;--fg:#14202b;--mut:#5d6b78;--line:#e3e8ee;--head:#eef2f7;--accent:#0b6bcb;
--reg:#e3f1e8;--regf:#14573a;--sub:#e4edfb;--subf:#1c4a8a;--glob:#f0e8fa;--globf:#5a2d86;--inh:#eceff2;--inhf:#4a5560}
@media(prefers-color-scheme:dark){:root{--bg:#0e141a;--card:#151d25;--fg:#e6ebf0;--mut:#93a1ae;--line:#26323d;--head:#1b2530;--accent:#5aa9f5;
--reg:#173325;--regf:#8fd8b0;--sub:#172a45;--subf:#9cc4f5;--glob:#2b1d3c;--globf:#cfa9f0;--inh:#232d37;--inhf:#a9b5c0}}
*{box-sizing:border-box}
body{margin:0;padding:32px 20px;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:1100px;margin:0 auto}
h1{margin:0 0 4px;font-size:24px;font-weight:650}
.sub-h{color:var(--mut);margin:0 0 18px}
.kpis{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:20px}
.kpi{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 16px;min-width:150px}
.kpi span{display:block;font-size:11px;letter-spacing:.07em;text-transform:uppercase;color:var(--mut)}
.kpi b{font:600 15px ui-monospace,SFMono-Regular,Menlo,monospace}
.wrap{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%;min-width:760px}
th,td{text-align:left;padding:10px 16px;border-bottom:1px solid var(--line);vertical-align:top}
th{position:sticky;top:0;background:var(--head);font-size:11.5px;letter-spacing:.07em;text-transform:uppercase;color:var(--mut)}
tr:last-child td{border-bottom:0} tbody tr:hover td{background:var(--head)}
td b{font-weight:600} code{display:block;color:var(--mut);font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
.n{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
.chip{display:inline-block;padding:2px 10px;border-radius:99px;font-size:12px;white-space:nowrap}
.c-reg{background:var(--reg);color:var(--regf)}.c-sub{background:var(--sub);color:var(--subf)}
.c-glob{background:var(--glob);color:var(--globf)}.c-inh{background:var(--inh);color:var(--inhf)}
</style>
<main>
<h1>Azure resource inventory</h1>
<p class="sub-h">Resources read from the Terraform state</p>
<div class="kpis">
<div class="kpi"><span>Subscription</span><b>$SUB</b></div>
<div class="kpi"><span>Resource group</span><b>$RG</b></div>
<div class="kpi"><span>Region</span><b>$REGION</b></div>
<div class="kpi"><span>Resources</span><b>$COUNT</b></div>
</div>
<div class="wrap"><table>
<thead><tr><th>Azure resource type<th>Resource name<th>Resource group<th>Region / scope</thead>
<tbody>
HTML
  jq -r "$ROWS | .[] | \"<tr><td><b>\(.[1])</b><code>\(.[0])</code><td class=n>\(.[2])<td class=n>\(.[3])<td><span class=\\\"chip c-\(if .[4] | test(\"^(Subscription|Resource scope)\") then \"sub\" elif .[4] == \"Global\" then \"glob\" elif .[4] == \"(parent)\" then \"inh\" else \"reg\" end)\\\">\(.[4])</span>\"" "$STATE"
  echo "</tbody></table></div></main>"; } > "$OUT"

echo; echo "HTML report: $OUT"
