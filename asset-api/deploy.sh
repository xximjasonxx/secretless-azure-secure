#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/asset-api"

RG="${AZURE_RESOURCE_GROUP:-rg-securetalk-poc-swc-mx01}"
LOCATION="${AZURE_LOCATION:-swedencentral}"

UAMI_NAME="uami-registry-acrpull-swc-mx01"
ACR_NAME="crapiregistryswcmx01"
ACA_ENV_NAME="cae-asset-api-swc-mx01"
ACA_APP_NAME="ca-asset-api-swc-mx01"
REDIS_CLUSTER_NAME="amr-assetapi-swc-mx01"
REDIS_DB_NAME="default"
REDIS_APA_NAME="caassetapiwrite"

IMAGE_TAG="asset-api:v1"
ACR_SERVER="${ACR_NAME}.azurecr.io"
TAGS="SecurityControl=Ignore app=asset-api demo=security-journey"

echo "Using resource group: $RG"
echo "Using location: $LOCATION"

if [[ "$(az group exists --name "$RG" -o tsv)" != "true" ]]; then
  az group create --name "$RG" --location "$LOCATION" --tags $TAGS -o none
fi

if ! az identity show --name "$UAMI_NAME" --resource-group "$RG" >/dev/null 2>&1; then
  az identity create --name "$UAMI_NAME" --resource-group "$RG" --location "$LOCATION" --tags $TAGS -o none
fi
UAMI_PRINCIPAL_ID="$(az identity show --name "$UAMI_NAME" --resource-group "$RG" --query principalId -o tsv)"
UAMI_ID="$(az identity show --name "$UAMI_NAME" --resource-group "$RG" --query id -o tsv)"

if ! az acr show --name "$ACR_NAME" --resource-group "$RG" >/dev/null 2>&1; then
  az acr create --name "$ACR_NAME" --resource-group "$RG" --location "$LOCATION" --sku Standard --admin-enabled false --tags $TAGS -o none
fi
ACR_ID="$(az acr show --name "$ACR_NAME" --resource-group "$RG" --query id -o tsv)"

EXISTING_ACR_PULL="$(az role assignment list \
  --assignee-object-id "$UAMI_PRINCIPAL_ID" \
  --scope "$ACR_ID" \
  --query "[?roleDefinitionName=='AcrPull'] | [0].id" \
  -o tsv)"
if [[ -z "$EXISTING_ACR_PULL" ]]; then
  az role assignment create \
    --assignee-object-id "$UAMI_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --scope "$ACR_ID" \
    --role AcrPull \
    -o none
fi

if ! az containerapp env show --name "$ACA_ENV_NAME" --resource-group "$RG" >/dev/null 2>&1; then
  az containerapp env create \
    --name "$ACA_ENV_NAME" \
    --resource-group "$RG" \
    --location "$LOCATION" \
    --logs-destination none \
    --tags $TAGS \
    -o none
fi

APP_EXISTS="false"
EXISTING_APP_API_KEY=""
if az containerapp show --name "$ACA_APP_NAME" --resource-group "$RG" >/dev/null 2>&1; then
  APP_EXISTS="true"
  EXISTING_APP_API_KEY="$(az containerapp show \
    --name "$ACA_APP_NAME" \
    --resource-group "$RG" \
    --query "properties.template.containers[0].env[?name=='ASSET_API_KEY'].value | [0]" \
    -o tsv 2>/dev/null || true)"
fi

if [[ -n "${ASSET_API_KEY:-}" ]]; then
  API_KEY="$ASSET_API_KEY"
elif [[ -n "$EXISTING_APP_API_KEY" ]]; then
  API_KEY="$EXISTING_APP_API_KEY"
else
  if [[ "$APP_EXISTS" == "true" ]]; then
    echo "ERROR: Existing container app found but ASSET_API_KEY could not be read."
    echo "Set ASSET_API_KEY explicitly to avoid accidental key rotation."
    exit 1
  fi
  API_KEY="$(python - <<'PY'
import base64
import uuid
print(base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip("="))
PY
)"
fi

if ! az redisenterprise show --name "$REDIS_CLUSTER_NAME" --resource-group "$RG" >/dev/null 2>&1; then
  az redisenterprise create \
    --cluster-name "$REDIS_CLUSTER_NAME" \
    --resource-group "$RG" \
    --location "$LOCATION" \
    --sku Balanced_B0 \
    --minimum-tls-version 1.2 \
    --public-network-access Enabled \
    --no-database \
    --tags $TAGS \
    -o none
fi

REDIS_DB_COUNT="$(az redisenterprise database list --resource-group "$RG" --cluster-name "$REDIS_CLUSTER_NAME" --query "length(@)" -o tsv 2>/dev/null || echo "0")"
if [[ "$REDIS_DB_COUNT" == "0" ]]; then
  az redisenterprise database create \
    --resource-group "$RG" \
    --cluster-name "$REDIS_CLUSTER_NAME" \
    --clustering-policy EnterpriseCluster \
    --modules name="RediSearch" \
    --access-keys-auth Disabled \
    --client-protocol Encrypted \
    -o none
fi

REDIS_HOST="$(az redisenterprise show --name "$REDIS_CLUSTER_NAME" --resource-group "$RG" --query hostName -o tsv)"
REDIS_PORT="$(az redisenterprise database show --resource-group "$RG" --cluster-name "$REDIS_CLUSTER_NAME" --query port -o tsv)"

az acr build --registry "$ACR_NAME" --image "$IMAGE_TAG" "$APP_DIR" -o none

if ! az containerapp show --name "$ACA_APP_NAME" --resource-group "$RG" >/dev/null 2>&1; then
  az containerapp create \
    --name "$ACA_APP_NAME" \
    --resource-group "$RG" \
    --environment "$ACA_ENV_NAME" \
    --image "${ACR_SERVER}/${IMAGE_TAG}" \
    --target-port 8000 \
    --ingress external \
    --registry-server "$ACR_SERVER" \
    --registry-identity "$UAMI_ID" \
    --user-assigned "$UAMI_ID" \
    --system-assigned \
    --min-replicas 0 \
    --max-replicas 2 \
    --cpu 0.5 \
    --memory 1.0Gi \
    --env-vars \
      ASSET_API_KEY="$API_KEY" \
      REDIS_HOST="$REDIS_HOST" \
      REDIS_PORT="$REDIS_PORT" \
      REDIS_OBJECT_ID="pending" \
    --tags $TAGS \
    -o none
else
  az containerapp identity assign \
    --name "$ACA_APP_NAME" \
    --resource-group "$RG" \
    --user-assigned "$UAMI_ID" \
    --system-assigned \
    -o none

  az containerapp registry set \
    --name "$ACA_APP_NAME" \
    --resource-group "$RG" \
    --server "$ACR_SERVER" \
    --identity "$UAMI_ID" \
    -o none

  az containerapp update \
    --name "$ACA_APP_NAME" \
    --resource-group "$RG" \
    --image "${ACR_SERVER}/${IMAGE_TAG}" \
    -o none
fi

APP_PRINCIPAL_ID="$(az containerapp show --name "$ACA_APP_NAME" --resource-group "$RG" --query identity.principalId -o tsv)"

EXISTING_APA="$(az redisenterprise database access-policy-assignment list \
  --resource-group "$RG" \
  --cluster-name "$REDIS_CLUSTER_NAME" \
  --database-name "$REDIS_DB_NAME" \
  --query "[?name=='${REDIS_APA_NAME}'] | [0].id" \
  -o tsv)"
if [[ -z "$EXISTING_APA" ]]; then
  az redisenterprise database access-policy-assignment create \
    --resource-group "$RG" \
    --cluster-name "$REDIS_CLUSTER_NAME" \
    --database-name "$REDIS_DB_NAME" \
    --access-policy-assignment-name "$REDIS_APA_NAME" \
    --access-policy-name default \
    --object-id "$APP_PRINCIPAL_ID" \
    -o none
fi

az containerapp update \
  --name "$ACA_APP_NAME" \
  --resource-group "$RG" \
  --image "${ACR_SERVER}/${IMAGE_TAG}" \
  --min-replicas 1 \
  --max-replicas 2 \
  --set-env-vars \
    ASSET_API_KEY="$API_KEY" \
    REDIS_HOST="$REDIS_HOST" \
    REDIS_PORT="$REDIS_PORT" \
    REDIS_OBJECT_ID="$APP_PRINCIPAL_ID" \
  -o none

FQDN="$(az containerapp show --name "$ACA_APP_NAME" --resource-group "$RG" --query properties.configuration.ingress.fqdn -o tsv)"

echo "ASSET_API_KEY=$API_KEY"
echo "HEALTH_URL=https://${FQDN}/health"
echo "ASSET_ENDPOINT=https://${FQDN}/assets?limit=5"
