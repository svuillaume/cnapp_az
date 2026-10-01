#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <APP-ID>"
  exit 1
fi

APP_ID="$1"
SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

if [ -z "$SP_ID" ]; then
  echo "Service Principal not found: $APP_ID"
  exit 1
fi

echo "=== Service Principal ==="
echo "App ID:    $APP_ID"
echo "Object ID: $SP_ID"

echo
echo "=== Entra ID Directory Roles ==="
az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/memberOf/microsoft.graph.directoryRole" --query "value[].{Role:displayName,RoleId:id}" -o table

echo
echo "=== Azure RBAC Roles ==="
az role assignment list --assignee "$SP_ID" --all --include-inherited --query "[].{Role:roleDefinitionName,Scope:scope}" -o table
