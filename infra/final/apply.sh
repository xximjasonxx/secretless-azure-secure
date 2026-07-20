#!/usr/bin/env bash
set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$STAGE_DIR/../.." && pwd)"

get_env_value() {
  local key="$1"
  azd env get-value "$key" --cwd "$STAGE_DIR"
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
    echo "ERROR: No App Service found in resource group '$rg'."
    echo "Run 'azd up' in infra/final to deploy the baseline resources first."
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
    echo "ERROR: No Storage account found in resource group '$rg'."
    echo "Run 'azd up' in infra/final to deploy the baseline resources first."
    exit 1
  fi

  echo "ERROR: Multiple Storage accounts found in '$rg'. Set AZURE_STORAGE_ACCOUNT_NAME in this stage environment."
  exit 1
}

ensure_role_assignment() {
  local role_name="$1"
  local scope="$2"
  local principal_id="$3"
  local existing
  existing="$(az role assignment list \
    --assignee-object-id "$principal_id" \
    --scope "$scope" \
    --query "[?roleDefinitionName=='$role_name'] | [0].id" \
    -o tsv)"

  if [[ -n "$existing" ]]; then
    echo "Role already assigned: $role_name"
    return 0
  fi

  echo "Assigning role: $role_name"
  az role assignment create \
    --assignee-object-id "$principal_id" \
    --assignee-principal-type ServicePrincipal \
    --role "$role_name" \
    --scope "$scope" \
    --only-show-errors \
    -o none
}

RG="${AZURE_RESOURCE_GROUP:-$(get_env_value AZURE_RESOURCE_GROUP 2>/dev/null || true)}"
if [[ -z "$RG" ]]; then
  echo "ERROR: AZURE_RESOURCE_GROUP is not set. Run 'azd up' from this folder first."
  exit 1
fi

APP_NAME="${AZURE_WEBAPP_NAME:-}"
if [[ -z "$APP_NAME" ]]; then
  APP_NAME="$(discover_webapp_name "$RG")"
fi

STORAGE_NAME="${AZURE_STORAGE_ACCOUNT_NAME:-}"
if [[ -z "$STORAGE_NAME" ]]; then
  STORAGE_NAME="$(discover_storage_name "$RG")"
fi

LOCATION="${AZURE_LOCATION:-$(get_env_value AZURE_LOCATION 2>/dev/null || true)}"
if [[ -z "$LOCATION" ]]; then
  LOCATION="$(az group show --name "$RG" --query location -o tsv)"
fi

COMMENTS_TABLE="${ASSET_COMMENTS_TABLE:-$(get_env_value ASSET_COMMENTS_TABLE 2>/dev/null || echo assetcomments)}"
TICKETS_TABLE="${ASSET_TICKETS_TABLE:-$(get_env_value ASSET_TICKETS_TABLE 2>/dev/null || echo assettickets)}"
KEYVAULT_NAME="${AZURE_KEY_VAULT_NAME:-}"
KEYVAULT_ADMIN_OBJECT_ID="${KEYVAULT_ADMIN_OBJECT_ID:-}"
KEYVAULT_ADMIN_PRINCIPAL_TYPE="${KEYVAULT_ADMIN_PRINCIPAL_TYPE:-}"
SECRET_NAME="${ASSET_SERVICE_KEY_SECRET_NAME:-AssetServiceApiKey}"
APP_GATEWAY_NAME="${AZURE_APP_GATEWAY_NAME:-agw-${APP_NAME}}"
APP_GATEWAY_SKU="${AZURE_APP_GATEWAY_SKU:-Standard_v2}"

echo "Applying final secure configuration..."
echo "Resource group: $RG"
echo "App Service: $APP_NAME"
echo "Storage account: $STORAGE_NAME"
if [[ -n "$KEYVAULT_NAME" ]]; then
  echo "Key Vault (requested name): $KEYVAULT_NAME"
fi

echo "Ensuring App Service system-assigned identity is enabled..."
if ! APP_PRINCIPAL_ID="$(az webapp identity assign \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --query principalId \
  -o tsv)"; then
  echo "ERROR: Failed to enable or read App Service managed identity for '$APP_NAME'."
  exit 1
fi

ST_SCOPE="$(az storage account show --resource-group "$RG" --name "$STORAGE_NAME" --query id -o tsv)"
ensure_role_assignment "Storage Table Data Contributor" "$ST_SCOPE" "$APP_PRINCIPAL_ID"
TABLES_URI="https://${STORAGE_NAME}.table.core.windows.net/"

if [[ -z "$KEYVAULT_ADMIN_OBJECT_ID" ]]; then
  ACCOUNT_USER_TYPE="$(az account show --query user.type -o tsv 2>/dev/null || true)"
  ACCOUNT_USER_NAME="$(az account show --query user.name -o tsv 2>/dev/null || true)"

  ACCOUNT_USER_TYPE_NORMALIZED="$(printf '%s' "$ACCOUNT_USER_TYPE" | tr '[:upper:]' '[:lower:]')"
  case "$ACCOUNT_USER_TYPE_NORMALIZED" in
    serviceprincipal)
      KEYVAULT_ADMIN_OBJECT_ID="$(az ad sp show --id "$ACCOUNT_USER_NAME" --query id -o tsv 2>/dev/null || true)"
      if [[ -z "$KEYVAULT_ADMIN_PRINCIPAL_TYPE" ]]; then
        KEYVAULT_ADMIN_PRINCIPAL_TYPE="ServicePrincipal"
      fi
      ;;
    *)
      KEYVAULT_ADMIN_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
      if [[ -z "$KEYVAULT_ADMIN_PRINCIPAL_TYPE" ]]; then
        KEYVAULT_ADMIN_PRINCIPAL_TYPE="User"
      fi
      ;;
  esac
fi

if [[ -z "$KEYVAULT_ADMIN_PRINCIPAL_TYPE" ]]; then
  KEYVAULT_ADMIN_PRINCIPAL_TYPE="User"
fi

if [[ -z "$KEYVAULT_ADMIN_OBJECT_ID" ]]; then
  echo "ERROR: Could not resolve KEYVAULT_ADMIN_OBJECT_ID from current Azure CLI context."
  echo "Set KEYVAULT_ADMIN_OBJECT_ID explicitly in the stage environment and retry."
  exit 1
fi

ASSET_SERVICE_API_KEY_VALUE="${ASSET_SERVICE_API_KEY_VALUE:-$(az webapp config appsettings list \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --query "[?name=='ASSET_SERVICE_API_KEY'].value | [0]" \
  -o tsv)}"
PRESERVE_EXISTING_KEYVAULT_SECRET="false"

KEYVAULT_REF_REGEX='^@Microsoft\.KeyVault\(SecretUri=([^)]+)\)$'
if [[ "$ASSET_SERVICE_API_KEY_VALUE" =~ $KEYVAULT_REF_REGEX ]]; then
  EXISTING_SECRET_URI="${BASH_REMATCH[1]}"
  EXISTING_SECRET_VALUE="$(az keyvault secret show --id "$EXISTING_SECRET_URI" --query value -o tsv 2>/dev/null || true)"
  if [[ -n "$EXISTING_SECRET_VALUE" ]]; then
    ASSET_SERVICE_API_KEY_VALUE="$EXISTING_SECRET_VALUE"
  else
    echo "Could not read existing Key Vault secret value from this network context."
    echo "Continuing without secret reseed; existing Key Vault secret value will be preserved."
    PRESERVE_EXISTING_KEYVAULT_SECRET="true"
    ASSET_SERVICE_API_KEY_VALUE=""
  fi
fi

if [[ "$PRESERVE_EXISTING_KEYVAULT_SECRET" != "true" && -z "$ASSET_SERVICE_API_KEY_VALUE" ]]; then
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

echo "Deploying final network and Key Vault infrastructure..."
set +e
DEPLOY_OUTPUTS="$(az deployment group create \
  --resource-group "$RG" \
  --template-file "$REPO_ROOT/infra/final/main.bicep" \
  --parameters "${DEPLOY_PARAMS[@]}" \
  --query "[properties.outputs.keyVaultName.value,properties.outputs.keyVaultUri.value,properties.outputs.finalVnetName.value,properties.outputs.applicationGatewayPublicIpName.value,properties.outputs.applicationGatewayPublicFqdn.value]" \
  --only-show-errors \
  -o tsv)"
DEPLOY_EXIT_CODE=$?
set -e
if [[ $DEPLOY_EXIT_CODE -ne 0 ]]; then
  if [[ -n "$DEPLOY_OUTPUTS" ]]; then
    echo "$DEPLOY_OUTPUTS" >&2
  fi
  exit $DEPLOY_EXIT_CODE
fi

KEYVAULT_NAME="$(printf '%s\n' "$DEPLOY_OUTPUTS" | sed -n '1p')"
KEYVAULT_URI="$(printf '%s\n' "$DEPLOY_OUTPUTS" | sed -n '2p')"
VNET_NAME="$(printf '%s\n' "$DEPLOY_OUTPUTS" | sed -n '3p')"
APP_GATEWAY_PUBLIC_IP_NAME="$(printf '%s\n' "$DEPLOY_OUTPUTS" | sed -n '4p')"
APP_GATEWAY_FQDN="$(printf '%s\n' "$DEPLOY_OUTPUTS" | sed -n '5p')"
if [[ -z "$KEYVAULT_NAME" || -z "$KEYVAULT_URI" || -z "$VNET_NAME" || -z "$APP_GATEWAY_PUBLIC_IP_NAME" ]]; then
  echo "ERROR: Missing expected deployment outputs from final infrastructure deployment."
  exit 1
fi
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

EXISTING_APP_GATEWAY="$(az network application-gateway list \
  --resource-group "$RG" \
  --query "[?name=='${APP_GATEWAY_NAME}'] | [0].name" \
  -o tsv 2>/dev/null || true)"
if [[ -z "$EXISTING_APP_GATEWAY" ]]; then
  az network application-gateway create \
    --name "$APP_GATEWAY_NAME" \
    --resource-group "$RG" \
    --location "$LOCATION" \
    --sku "$APP_GATEWAY_SKU" \
    --capacity 1 \
    --vnet-name "$VNET_NAME" \
    --subnet snet-appgw \
    --public-ip-address "$APP_GATEWAY_PUBLIC_IP_NAME" \
    --servers "${APP_NAME}.azurewebsites.net" \
    --frontend-port 80 \
    --http-settings-protocol Https \
    --http-settings-port 443 \
    --http-settings-cookie-based-affinity Disabled \
    --routing-rule-type Basic \
    --priority 100 \
    --only-show-errors \
    -o none
fi

APP_GATEWAY_IP="$(az network public-ip show \
  --resource-group "$RG" \
  --name "$APP_GATEWAY_PUBLIC_IP_NAME" \
  --query ipAddress \
  -o tsv)"

if [[ -z "$APP_GATEWAY_FQDN" ]]; then
  APP_GATEWAY_FQDN="$(az network public-ip show \
    --resource-group "$RG" \
    --name "$APP_GATEWAY_PUBLIC_IP_NAME" \
    --query dnsSettings.fqdn \
    -o tsv 2>/dev/null || true)"
fi

APP_GATEWAY_HOST="$APP_GATEWAY_FQDN"
if [[ -z "$APP_GATEWAY_HOST" ]]; then
  APP_GATEWAY_HOST="$APP_GATEWAY_IP"
fi

if [[ -z "$APP_GATEWAY_HOST" ]]; then
  echo "ERROR: Could not resolve a public endpoint for Application Gateway '$APP_GATEWAY_NAME'."
  exit 1
fi

echo "Updating app settings for final secure mode..."
az webapp config appsettings set \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --settings \
    APP_SECURITY_STAGE=final \
    STORAGE_CONNECTION_STRING= \
    STORAGE_TABLES_URI="$TABLES_URI" \
    ASSET_COMMENTS_TABLE="$COMMENTS_TABLE" \
    ASSET_TICKETS_TABLE="$TICKETS_TABLE" \
    ASSET_SERVICE_API_KEY="@Microsoft.KeyVault(SecretUri=${SECRET_URI})" \
  --only-show-errors \
  -o none

APP_GATEWAY_URL="http://${APP_GATEWAY_HOST}"
azd env set APP_GATEWAY_URL "$APP_GATEWAY_URL" --cwd "$STAGE_DIR" >/dev/null
azd env set API_URL "$APP_GATEWAY_URL" --cwd "$STAGE_DIR" >/dev/null
if [[ -n "$APP_GATEWAY_FQDN" ]]; then
  azd env set APP_GATEWAY_FQDN "$APP_GATEWAY_FQDN" --cwd "$STAGE_DIR" >/dev/null
fi
if [[ -n "$APP_GATEWAY_IP" ]]; then
  azd env set APP_GATEWAY_IP "$APP_GATEWAY_IP" --cwd "$STAGE_DIR" >/dev/null
fi
echo "Application Gateway URL: $APP_GATEWAY_URL"
echo "Open in browser:"
echo "$APP_GATEWAY_URL"

azd env set AZURE_WEBAPP_NAME "$APP_NAME" --cwd "$STAGE_DIR" >/dev/null
azd env set AZURE_STORAGE_ACCOUNT_NAME "$STORAGE_NAME" --cwd "$STAGE_DIR" >/dev/null
azd env set AZURE_KEY_VAULT_NAME "$KEYVAULT_NAME" --cwd "$STAGE_DIR" >/dev/null
azd env set KEYVAULT_URI "$KEYVAULT_URI" --cwd "$STAGE_DIR" >/dev/null
azd env set STORAGE_TABLES_URI "$TABLES_URI" --cwd "$STAGE_DIR" >/dev/null
azd env set ASSET_COMMENTS_TABLE "$COMMENTS_TABLE" --cwd "$STAGE_DIR" >/dev/null
azd env set ASSET_TICKETS_TABLE "$TICKETS_TABLE" --cwd "$STAGE_DIR" >/dev/null

echo "Final stage complete."
