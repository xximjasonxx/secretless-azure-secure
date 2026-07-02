#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

get_env_value() {
  local key="$1"
  azd env get-value "$key" --cwd "$ROOT_DIR"
}

RG="${AZURE_RESOURCE_GROUP:-$(get_env_value AZURE_RESOURCE_GROUP)}"
APP_NAME="${AZURE_WEBAPP_NAME:-$(get_env_value AZURE_WEBAPP_NAME)}"
STORAGE_NAME="${AZURE_STORAGE_ACCOUNT_NAME:-$(get_env_value AZURE_STORAGE_ACCOUNT_NAME)}"
COMMENTS_TABLE="${ASSET_COMMENTS_TABLE:-$(get_env_value ASSET_COMMENTS_TABLE 2>/dev/null || echo assetcomments)}"
TICKETS_TABLE="${ASSET_TICKETS_TABLE:-$(get_env_value ASSET_TICKETS_TABLE 2>/dev/null || echo assettickets)}"

echo "Applying step1 managed identity + RBAC changes..."
echo "Resource group: $RG"
echo "App Service: $APP_NAME"
echo "Storage account: $STORAGE_NAME"

echo "Ensuring App Service system-assigned identity is enabled..."
APP_PRINCIPAL_ID="$(az webapp identity assign \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --query principalId \
  -o tsv)"

ST_SCOPE="$(az storage account show --resource-group "$RG" --name "$STORAGE_NAME" --query id -o tsv)"

ensure_role_assignment() {
  local role_name="$1"
  local scope="$2"
  local existing
  existing="$(az role assignment list \
    --assignee-object-id "$APP_PRINCIPAL_ID" \
    --scope "$scope" \
    --query "[?roleDefinitionName=='$role_name'] | [0].id" \
    -o tsv)"

  if [[ -n "$existing" ]]; then
    echo "Role already assigned: $role_name"
    return 0
  fi

  echo "Assigning role: $role_name"
  az role assignment create \
    --assignee-object-id "$APP_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$role_name" \
    --scope "$scope" \
    --only-show-errors \
    -o none
}

ensure_role_assignment "Storage Table Data Contributor" "$ST_SCOPE"

TABLES_URI="https://${STORAGE_NAME}.table.core.windows.net/"

echo "Updating app settings for managed identity mode..."
az webapp config appsettings set \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --settings \
    APP_SECURITY_STAGE=step1 \
    STORAGE_CONNECTION_STRING= \
    STORAGE_TABLES_URI="$TABLES_URI" \
    ASSET_COMMENTS_TABLE="$COMMENTS_TABLE" \
    ASSET_TICKETS_TABLE="$TICKETS_TABLE" \
  --only-show-errors \
  -o none

echo "Step1 complete."
echo "Note: RBAC propagation can take a few minutes."
