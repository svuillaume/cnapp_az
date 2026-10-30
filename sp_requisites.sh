#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <service-principal-object-id> <subscription-id>\n' \
    "$(basename "$0")" >&2
}

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

sp_object_id="$1"
subscription_id="$2"
uuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

if [[ ! "$sp_object_id" =~ $uuid_pattern ]]; then
  printf 'Error: service-principal object ID is not a valid UUID.\n' >&2
  exit 2
fi

if [[ ! "$subscription_id" =~ $uuid_pattern ]]; then
  printf 'Error: subscription ID is not a valid UUID.\n' >&2
  exit 2
fi

if ! command -v az >/dev/null 2>&1; then
  printf 'Error: Azure CLI (az) is not installed or not in PATH.\n' >&2
  exit 2
fi

scope="/subscriptions/$subscription_id"
graph_url="https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20'$sp_object_id'&\$expand=roleDefinition"

owner_count="$(
  az role assignment list \
    --assignee-object-id "$sp_object_id" \
    --scope "$scope" \
    --include-inherited \
    --query "length([?roleDefinitionName == 'Owner'])" \
    --output tsv
)"

app_admin_count="$(
  az rest \
    --method GET \
    --url "$graph_url" \
    --query "length(value[?roleDefinition.displayName == 'Application Administrator'])" \
    --output tsv
)"

privileged_admin_count="$(
  az rest \
    --method GET \
    --url "$graph_url" \
    --query "length(value[?roleDefinition.displayName == 'Privileged Role Administrator'])" \
    --output tsv
)"

missing=0
printf 'Service principal: %s\n' "$sp_object_id"
printf 'Subscription:      %s\n\n' "$subscription_id"

if (( owner_count > 0 )); then
  printf 'PASS  Owner — %s\n' "$scope"
else
  printf 'FAIL  Owner — %s\n' "$scope"
  missing=1
fi

if (( app_admin_count > 0 )); then
  printf 'PASS  Application Administrator — Entra ID (active, direct)\n'
else
  printf 'FAIL  Application Administrator — Entra ID (active, direct)\n'
  missing=1
fi

if (( privileged_admin_count > 0 )); then
  printf 'PASS  Privileged Role Administrator — Entra ID (active, direct)\n'
else
  printf 'FAIL  Privileged Role Administrator — Entra ID (active, direct)\n'
  missing=1
fi

if (( missing != 0 )); then
  printf '\nOne or more required roles are missing.\n'
  exit 1
fi

printf '\nAll required roles are assigned.\n'
