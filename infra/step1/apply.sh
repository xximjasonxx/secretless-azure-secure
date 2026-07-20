#!/usr/bin/env bash
set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

is_invalid_env_value() {
  local value="${1:-}"
  [[ -z "$value" ]] && return 0
  [[ "$value" == *"ERROR:"* ]] && return 0
  [[ "$value" == *$'\n'* ]] && return 0
  return 1
}

get_env_value() {
  local key="$1"
  local value

  if ! value="$(azd env get-value "$key" --cwd "$STAGE_DIR" 2>/dev/null)"; then
    return 1
  fi

  if is_invalid_env_value "$value"; then
    return 1
  fi

  printf '%s' "$value"
}

resolve_value_or_default() {
  local value="${1:-}"
  local default_value="$2"

  if is_invalid_env_value "$value"; then
    printf '%s' "$default_value"
    return
  fi

  printf '%s' "$value"
}

discover_webapp_name() {
  local rg="$1"
  local count
  count="$(az webapp list --resource-group "$rg" --query "length(@)" -o tsv)"

  if [[ "$count" == "1" ]]; then
    az webapp list --resource-group "$rg" --query "[0].name" -o tsv
    return
  fi

  if [[ "$count" == "0" ]]; then
    echo "ERROR: No App Service found in resource group '$rg'. Run the start stage first."
    exit 1
  fi

  echo "ERROR: Multiple App Services found in '$rg'. Set AZURE_WEBAPP_NAME in this stage environment."
  exit 1
}

discover_storage_name() {
  local rg="$1"
  local count
  count="$(az storage account list --resource-group "$rg" --query "length(@)" -o tsv)"

  if [[ "$count" == "1" ]]; then
    az storage account list --resource-group "$rg" --query "[0].name" -o tsv
    return
  fi

  if [[ "$count" == "0" ]]; then
    echo "ERROR: No Storage account found in resource group '$rg'. Run the start stage first."
    exit 1
  fi

  echo "ERROR: Multiple Storage accounts found in '$rg'. Set AZURE_STORAGE_ACCOUNT_NAME in this stage environment."
  exit 1
}

RG="$(resolve_value_or_default "${AZURE_RESOURCE_GROUP:-$(get_env_value AZURE_RESOURCE_GROUP || true)}" "")"
if [[ -z "$RG" ]]; then
  echo "ERROR: AZURE_RESOURCE_GROUP is not set. Run 'azd up' from this folder first."
  exit 1
fi

APP_NAME="$(resolve_value_or_default "${AZURE_WEBAPP_NAME:-}" "")"
if [[ -z "$APP_NAME" ]]; then
  APP_NAME="$(discover_webapp_name "$RG")"
fi

STORAGE_NAME="$(resolve_value_or_default "${AZURE_STORAGE_ACCOUNT_NAME:-}" "")"
if [[ -z "$STORAGE_NAME" ]]; then
  STORAGE_NAME="$(discover_storage_name "$RG")"
fi

COMMENTS_TABLE="$(resolve_value_or_default "${ASSET_COMMENTS_TABLE:-$(get_env_value ASSET_COMMENTS_TABLE || true)}" "assetcomments")"
TICKETS_TABLE="$(resolve_value_or_default "${ASSET_TICKETS_TABLE:-$(get_env_value ASSET_TICKETS_TABLE || true)}" "assettickets")"

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

azd env set AZURE_WEBAPP_NAME "$APP_NAME" --cwd "$STAGE_DIR" >/dev/null
azd env set AZURE_STORAGE_ACCOUNT_NAME "$STORAGE_NAME" --cwd "$STAGE_DIR" >/dev/null
azd env set STORAGE_TABLES_URI "$TABLES_URI" --cwd "$STAGE_DIR" >/dev/null
azd env set ASSET_COMMENTS_TABLE "$COMMENTS_TABLE" --cwd "$STAGE_DIR" >/dev/null
azd env set ASSET_TICKETS_TABLE "$TICKETS_TABLE" --cwd "$STAGE_DIR" >/dev/null

echo "Step1 complete."
echo "Note: RBAC propagation can take a few minutes."
