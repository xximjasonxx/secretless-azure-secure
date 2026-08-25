#!/usr/bin/env bash
set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$STAGE_DIR/../.." && pwd)"
CERT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/secureapp-gateway-cert.XXXXXX")"
trap 'rm -rf -- "$CERT_DIR"' EXIT

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
  local principal_type="${4:-ServicePrincipal}"
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
    --assignee-principal-type "$principal_type" \
    --role "$role_name" \
    --scope "$scope" \
    --only-show-errors \
    -o none
}

remove_role_assignment_at_scope() {
  local role_name="$1"
  local scope="$2"
  local principal_id="$3"
  local assignment_ids
  local assignment_id

  assignment_ids="$(az role assignment list \
    --assignee-object-id "$principal_id" \
    --scope "$scope" \
    --query "[?roleDefinitionName=='$role_name'] | [].id" \
    -o tsv)"

  while IFS= read -r assignment_id; do
    if [[ -n "$assignment_id" ]]; then
      echo "Removing obsolete role assignment: $role_name at $scope"
      az role assignment delete --ids "$assignment_id" --only-show-errors -o none
    fi
  done <<< "$assignment_ids"
}

ensure_custom_role_definition() {
  local role_name="Mission Control App Settings Reader"
  local role_definition_id="bae9b1f4-d2b2-44a0-b0d0-7ea87980d935"
  local scope="$1"
  local existing_role_name
  local existing_role_definition
  local scope_exists
  local updated_role_definition

  existing_role_name="$(az role definition list \
    --custom-role-only true \
    --query "[?roleName=='$role_name'] | [0].roleName" \
    -o tsv 2>/dev/null || true)"

  if [[ -z "$existing_role_name" ]]; then
    existing_role_name="$(az role definition list \
      --name "$role_definition_id" \
      --query "[0].roleName" \
      -o tsv 2>/dev/null || true)"
  fi

  if [[ -n "$existing_role_name" ]]; then
    existing_role_definition="$(az role definition list \
      --name "$existing_role_name" \
      --query "[0]" \
      -o json)"
    scope_exists="$(printf '%s' "$existing_role_definition" | jq -r --arg scope "$scope" 'any(.assignableScopes[]?; . == $scope)')"

    if [[ "$scope_exists" != "true" ]]; then
      echo "Updating custom role assignable scopes: $existing_role_name" >&2
      updated_role_definition="$(printf '%s' "$existing_role_definition" | jq -c --arg scope "$scope" '
        {
          Name: .name,
          Id: .id,
          roleName: .roleName,
          Description: .description,
          Actions: .permissions[0].actions,
          NotActions: .permissions[0].notActions,
          DataActions: .permissions[0].dataActions,
          NotDataActions: .permissions[0].notDataActions,
          AssignableScopes: ((.assignableScopes // []) + [$scope] | unique)
        }')"

      az role definition update \
        --role-definition "$updated_role_definition" \
        --only-show-errors \
        -o none
    else
      echo "Custom role already includes scope: $existing_role_name" >&2
    fi

    printf '%s\n' "$(printf '%s' "$existing_role_definition" | jq -r '.id')"
    return 0
  fi

  echo "Creating custom role: $role_name" >&2
  az role definition create \
    --role-definition "$(jq -n \
      --arg roleName "$role_name" \
      --arg description "Allows Mission Control to inspect raw App Service app settings without write access." \
      --arg scope "$scope" \
      '{
        Name: $roleName,
        IsCustom: true,
        Description: $description,
        Actions: [
          "Microsoft.Web/sites/read",
          "Microsoft.Web/sites/config/read",
          "Microsoft.Web/sites/config/list/action"
        ],
        NotActions: [],
        AssignableScopes: [$scope]
      }')" \
    --only-show-errors \
    -o none

  for _ in {1..30}; do
    if az role definition list \
      --name "$role_name" \
      --query "[?roleName=='$role_name'] | [0].id" \
      -o tsv 2>/dev/null | grep -q '/providers/Microsoft.Authorization/roleDefinitions/'; then
      break
    fi
    sleep 2
  done

  if ! az role definition list \
    --name "$role_name" \
    --query "[?roleName=='$role_name'] | [0].id" \
    -o tsv 2>/dev/null | grep -q '/providers/Microsoft.Authorization/roleDefinitions/'; then
    echo "ERROR: Custom role '$role_name' was not available after creation." >&2
    return 1
  fi

  az role definition list \
    --name "$role_name" \
    --query "[?roleName=='$role_name'] | [0].id" \
    -o tsv
}

RG="$(resolve_value_or_default "${AZURE_RESOURCE_GROUP:-$(get_env_value AZURE_RESOURCE_GROUP || true)}" "")"
if [[ -z "$RG" ]]; then
  echo "ERROR: AZURE_RESOURCE_GROUP is not set. Run 'azd up' from this folder first."
  exit 1
fi
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

APP_NAME="$(resolve_value_or_default "${AZURE_WEBAPP_NAME:-}" "")"
if [[ -z "$APP_NAME" ]]; then
  APP_NAME="$(discover_webapp_name "$RG")"
fi

STORAGE_NAME="$(resolve_value_or_default "${AZURE_STORAGE_ACCOUNT_NAME:-}" "")"
if [[ -z "$STORAGE_NAME" ]]; then
  STORAGE_NAME="$(discover_storage_name "$RG")"
fi

VNET_NAME="$(resolve_value_or_default "${VNET_NAME:-$(get_env_value VNET_NAME || true)}" "")"
if [[ -z "$VNET_NAME" ]]; then
  echo "ERROR: VNET_NAME is not set. Run 'azd provision' to create the baseline infrastructure first."
  exit 1
fi

LOCATION="$(resolve_value_or_default "${AZURE_LOCATION:-$(get_env_value AZURE_LOCATION || true)}" "")"
if [[ -z "$LOCATION" ]]; then
  LOCATION="$(az group show --name "$RG" --query location -o tsv)"
fi

COMMENTS_TABLE="$(resolve_value_or_default "${ASSET_COMMENTS_TABLE:-$(get_env_value ASSET_COMMENTS_TABLE || true)}" "assetcomments")"
TICKETS_TABLE="$(resolve_value_or_default "${ASSET_TICKETS_TABLE:-$(get_env_value ASSET_TICKETS_TABLE || true)}" "assettickets")"
KEYVAULT_NAME="$(resolve_value_or_default "${AZURE_KEY_VAULT_NAME:-$(get_env_value AZURE_KEY_VAULT_NAME || true)}" "")"
KEYVAULT_ADMIN_OBJECT_ID="$(resolve_value_or_default "${KEYVAULT_ADMIN_OBJECT_ID:-$(get_env_value KEYVAULT_ADMIN_OBJECT_ID || true)}" "")"
KEYVAULT_ADMIN_PRINCIPAL_TYPE="$(resolve_value_or_default "${KEYVAULT_ADMIN_PRINCIPAL_TYPE:-$(get_env_value KEYVAULT_ADMIN_PRINCIPAL_TYPE || true)}" "")"
SECRET_NAME="$(resolve_value_or_default "${ASSET_SERVICE_KEY_SECRET_NAME:-AssetServiceApiKey}" "AssetServiceApiKey")"
APP_GATEWAY_NAME="$(resolve_value_or_default "${AZURE_APP_GATEWAY_NAME:-agw-${APP_NAME}}" "agw-${APP_NAME}")"
APP_GATEWAY_SKU="$(resolve_value_or_default "${AZURE_APP_GATEWAY_SKU:-Standard_v2}" "Standard_v2")"

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
TABLE_SERVICE_SCOPE="${ST_SCOPE}/tableServices/default"
COMMENTS_TABLE_SCOPE="${TABLE_SERVICE_SCOPE}/tables/${COMMENTS_TABLE}"
TICKETS_TABLE_SCOPE="${TABLE_SERVICE_SCOPE}/tables/${TICKETS_TABLE}"

# Remove legacy account-scoped assignments left by earlier incremental deployments.
remove_role_assignment_at_scope "Storage Account Contributor" "$ST_SCOPE" "$APP_PRINCIPAL_ID"
remove_role_assignment_at_scope "Storage Table Data Contributor" "$ST_SCOPE" "$APP_PRINCIPAL_ID"
remove_role_assignment_at_scope "Storage Blob Data Reader" "$ST_SCOPE" "$APP_PRINCIPAL_ID"

ensure_role_assignment "Storage Table Data Contributor" "$COMMENTS_TABLE_SCOPE" "$APP_PRINCIPAL_ID"
ensure_role_assignment "Storage Table Data Contributor" "$TICKETS_TABLE_SCOPE" "$APP_PRINCIPAL_ID"
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
  ASSET_SERVICE_API_KEY_VALUE="demo-$(openssl rand -hex 24)"
  echo "No Asset API key supplied; generated a runtime-only demo value for Key Vault reference validation."
fi

DEPLOY_PARAMS=(
  "location=$LOCATION"
  "appName=$APP_NAME"
  "storageAccountName=$STORAGE_NAME"
  "vnetName=$VNET_NAME"
  "assetServiceApiKeySecretValue=$ASSET_SERVICE_API_KEY_VALUE"
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

KEYVAULT_SCOPE="$(az keyvault show --resource-group "$RG" --name "$KEYVAULT_NAME" --query id -o tsv)"
APP_SCOPE="$(az webapp show --resource-group "$RG" --name "$APP_NAME" --query id -o tsv)"
RG_SCOPE="$(az group show --name "$RG" --query id -o tsv)"

KEYVAULT_PRIVATE_ENDPOINT_NAMES="$(az network private-endpoint list \
  --resource-group "$RG" \
  --query "[?privateLinkServiceConnections[0].privateLinkServiceId=='$KEYVAULT_SCOPE'] | [].name" \
  -o tsv 2>/dev/null || true)"
KEEP_KEYVAULT_PRIVATE_ENDPOINT_NAME="$(printf '%s\n' "$KEYVAULT_PRIVATE_ENDPOINT_NAMES" | sed '/^$/d' | head -n 1)"
while IFS= read -r key_vault_private_endpoint_name; do
  if [[ -n "$key_vault_private_endpoint_name" && "$key_vault_private_endpoint_name" != "$KEEP_KEYVAULT_PRIVATE_ENDPOINT_NAME" ]]; then
    echo "Removing obsolete duplicate Key Vault private endpoint: $key_vault_private_endpoint_name"
    az network private-endpoint delete \
      --resource-group "$RG" \
      --name "$key_vault_private_endpoint_name" \
      --only-show-errors \
      -o none
  fi
done <<< "$KEYVAULT_PRIVATE_ENDPOINT_NAMES"

APP_SETTINGS_READER_ROLE_NAME="$(ensure_custom_role_definition "$RG_SCOPE")"
ensure_role_assignment "Key Vault Administrator" "$KEYVAULT_SCOPE" "$KEYVAULT_ADMIN_OBJECT_ID" "$KEYVAULT_ADMIN_PRINCIPAL_TYPE"
ensure_role_assignment "Key Vault Secrets User" "$KEYVAULT_SCOPE" "$APP_PRINCIPAL_ID" ServicePrincipal
ensure_role_assignment "$APP_SETTINGS_READER_ROLE_NAME" "$APP_SCOPE" "$APP_PRINCIPAL_ID" ServicePrincipal

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

HTTPS_FRONTEND_PORT_NAME="$(az network application-gateway frontend-port list \
  --resource-group "$RG" \
  --gateway-name "$APP_GATEWAY_NAME" \
  --query '[?port==`443`] | [0].name' \
  -o tsv 2>/dev/null || true)"
if [[ -z "$HTTPS_FRONTEND_PORT_NAME" ]]; then
  HTTPS_FRONTEND_PORT_NAME="appGatewayHttpsFrontendPort"
  az network application-gateway frontend-port create \
    --resource-group "$RG" \
    --gateway-name "$APP_GATEWAY_NAME" \
    --name "$HTTPS_FRONTEND_PORT_NAME" \
    --port 443 \
    --only-show-errors \
    -o none
fi

# App Service requires its hostname for both the Host header and TLS SNI.
az network application-gateway http-settings update \
  --resource-group "$RG" \
  --gateway-name "$APP_GATEWAY_NAME" \
  --name "appGatewayBackendHttpSettings" \
  --host-name-from-backend-pool false \
  --host-name "${APP_NAME}.azurewebsites.net" \
  --only-show-errors \
  -o none

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
    AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID" \
    AZURE_RESOURCE_GROUP="$RG" \
    AZURE_WEBAPP_NAME="$APP_NAME" \
    ASSET_SERVICE_API_KEY="@Microsoft.KeyVault(SecretUri=${SECRET_URI})" \
  --only-show-errors \
  -o none

APP_GATEWAY_CERT_NAME="appGatewayDemoCert"
APP_GATEWAY_CERT_PASSWORD="$(openssl rand -hex 24)"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -keyout "$CERT_DIR/gateway.key" \
  -out "$CERT_DIR/gateway.crt" \
  -days 365 \
  -subj "/CN=${APP_GATEWAY_HOST}" \
  -addext "subjectAltName=DNS:${APP_GATEWAY_HOST}" \
  -quiet
openssl pkcs12 -export \
  -out "$CERT_DIR/gateway.pfx" \
  -inkey "$CERT_DIR/gateway.key" \
  -in "$CERT_DIR/gateway.crt" \
  -passout "pass:${APP_GATEWAY_CERT_PASSWORD}" \
  -name "$APP_GATEWAY_CERT_NAME"

EXISTING_APP_GATEWAY_CERT="$(az network application-gateway ssl-cert list \
  --resource-group "$RG" \
  --gateway-name "$APP_GATEWAY_NAME" \
  --query "[?name=='${APP_GATEWAY_CERT_NAME}'] | [0].name" \
  -o tsv 2>/dev/null || true)"
if [[ -n "$EXISTING_APP_GATEWAY_CERT" ]]; then
  az network application-gateway ssl-cert update \
    --resource-group "$RG" \
    --gateway-name "$APP_GATEWAY_NAME" \
    --name "$APP_GATEWAY_CERT_NAME" \
    --cert-file "$CERT_DIR/gateway.pfx" \
    --cert-password "$APP_GATEWAY_CERT_PASSWORD" \
    --only-show-errors \
    -o none
else
  az network application-gateway ssl-cert create \
    --resource-group "$RG" \
    --gateway-name "$APP_GATEWAY_NAME" \
    --name "$APP_GATEWAY_CERT_NAME" \
    --cert-file "$CERT_DIR/gateway.pfx" \
    --cert-password "$APP_GATEWAY_CERT_PASSWORD" \
    --only-show-errors \
    -o none
fi

APP_GATEWAY_LISTENER_NAME="$(az network application-gateway http-listener list \
  --resource-group "$RG" \
  --gateway-name "$APP_GATEWAY_NAME" \
  --query "[0].name" \
  -o tsv)"
az network application-gateway http-listener update \
  --resource-group "$RG" \
  --gateway-name "$APP_GATEWAY_NAME" \
  --name "$APP_GATEWAY_LISTENER_NAME" \
  --frontend-port "$HTTPS_FRONTEND_PORT_NAME" \
  --ssl-cert "$APP_GATEWAY_CERT_NAME" \
  --only-show-errors \
  -o none

APP_GATEWAY_URL="https://${APP_GATEWAY_HOST}"
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
