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
LOCATION="${AZURE_LOCATION:-$(get_env_value AZURE_LOCATION)}"
KEYVAULT_NAME="${AZURE_KEY_VAULT_NAME:-$(get_env_value AZURE_KEY_VAULT_NAME 2>/dev/null || true)}"
KEYVAULT_ADMIN_OBJECT_ID="${KEYVAULT_ADMIN_OBJECT_ID:-61a37498-9ab6-43d2-b70f-706fd58274e7}"
KEYVAULT_ADMIN_PRINCIPAL_TYPE="${KEYVAULT_ADMIN_PRINCIPAL_TYPE:-User}"
SECRET_NAME="${ASSET_SERVICE_KEY_SECRET_NAME:-AssetServiceApiKey}"

echo "Applying step2 private networking resources..."
echo "Resource group: $RG"
echo "App Service: $APP_NAME"
echo "Storage account: $STORAGE_NAME"
if [[ -n "$KEYVAULT_NAME" ]]; then
  echo "Key Vault (requested name): $KEYVAULT_NAME"
fi

echo "Ensuring App Service system-assigned identity is enabled..."
APP_PRINCIPAL_ID="$(az webapp identity assign \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --query principalId \
  -o tsv)"

ASSET_SERVICE_API_KEY_VALUE="${ASSET_SERVICE_API_KEY_VALUE:-$(az webapp config appsettings list \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --query "[?name=='ASSET_SERVICE_API_KEY'].value | [0]" \
  -o tsv)}"

KEYVAULT_REF_REGEX='^@Microsoft\.KeyVault\(SecretUri=([^)]+)\)$'
if [[ "$ASSET_SERVICE_API_KEY_VALUE" =~ $KEYVAULT_REF_REGEX ]]; then
  EXISTING_SECRET_URI="${BASH_REMATCH[1]}"
  EXISTING_SECRET_VALUE="$(az keyvault secret show --id "$EXISTING_SECRET_URI" --query value -o tsv 2>/dev/null || true)"
  if [[ -n "$EXISTING_SECRET_VALUE" ]]; then
    ASSET_SERVICE_API_KEY_VALUE="$EXISTING_SECRET_VALUE"
  else
    echo "Unable to resolve existing Key Vault reference for ASSET_SERVICE_API_KEY."
    echo "Set ASSET_SERVICE_API_KEY_VALUE to provide the secret value explicitly and retry."
    exit 1
  fi
fi

if [[ -z "$ASSET_SERVICE_API_KEY_VALUE" ]]; then
  ASSET_SERVICE_API_KEY_VALUE="demo-insecure-api-key"
fi

DEPLOY_PARAMS=(
  "location=$LOCATION"
  "appName=$APP_NAME"
  "storageAccountName=$STORAGE_NAME"
  "appPrincipalObjectId=$APP_PRINCIPAL_ID"
  "assetServiceApiKeySecretValue=$ASSET_SERVICE_API_KEY_VALUE"
  "keyVaultAdminObjectId=$KEYVAULT_ADMIN_OBJECT_ID"
  "keyVaultAdminPrincipalType=$KEYVAULT_ADMIN_PRINCIPAL_TYPE"
  "assetServiceApiKeySecretName=$SECRET_NAME"
)

if [[ -n "$KEYVAULT_NAME" ]]; then
  DEPLOY_PARAMS+=("keyVaultName=$KEYVAULT_NAME")
fi

DEPLOY_OUTPUTS="$(az deployment group create \
  --resource-group "$RG" \
  --template-file "$ROOT_DIR/infra/step2/main.bicep" \
  --parameters "${DEPLOY_PARAMS[@]}" \
  --query "[properties.outputs.keyVaultName.value,properties.outputs.keyVaultUri.value]" \
  --only-show-errors \
  -o tsv)"

KEYVAULT_NAME="$(printf '%s\n' "$DEPLOY_OUTPUTS" | sed -n '1p')"
KEYVAULT_URI="$(printf '%s\n' "$DEPLOY_OUTPUTS" | sed -n '2p')"
SECRET_URI="${KEYVAULT_URI}secrets/${SECRET_NAME}/"

echo "Locking resources to private-only access..."
az keyvault update \
  --resource-group "$RG" \
  --name "$KEYVAULT_NAME" \
  --public-network-access Disabled \
  --default-action Deny \
  --only-show-errors \
  -o none

az storage account update \
  --resource-group "$RG" \
  --name "$STORAGE_NAME" \
  --public-network-access Disabled \
  --default-action Deny \
  --only-show-errors \
  -o none

az resource update \
  --resource-group "$RG" \
  --resource-type Microsoft.Web/sites \
  --name "$APP_NAME" \
  --set properties.publicNetworkAccess=Disabled \
  --only-show-errors \
  -o none

az webapp config appsettings set \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --settings \
    APP_SECURITY_STAGE=step2 \
    ASSET_SERVICE_API_KEY="@Microsoft.KeyVault(SecretUri=${SECRET_URI})" \
  --only-show-errors \
  -o none

APP_GATEWAY_IP="$(az network public-ip list \
  --resource-group "$RG" \
  --query "[?contains(name,'pip-appgw-')].ipAddress | [0]" \
  -o tsv)"

echo "Step2 complete."
if [[ -n "$APP_GATEWAY_IP" ]]; then
  azd env set APP_GATEWAY_URL "http://${APP_GATEWAY_IP}" --cwd "$ROOT_DIR" >/dev/null
  echo "Application Gateway URL: http://${APP_GATEWAY_IP}"
fi

azd env set AZURE_KEY_VAULT_NAME "$KEYVAULT_NAME" --cwd "$ROOT_DIR" >/dev/null
azd env set KEYVAULT_URI "$KEYVAULT_URI" --cwd "$ROOT_DIR" >/dev/null
echo "Key Vault created: $KEYVAULT_NAME"
