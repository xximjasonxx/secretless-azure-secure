#!/usr/bin/env bash
set -euo pipefail

LOCATION="${LOCATION:-swedencentral}"
RG="${RG:-rg-secretless-containers-swc}"
SUFFIX="${SUFFIX:-$(openssl rand -hex 4)}"
ACR_NAME="${ACR_NAME:-secretlessacr${SUFFIX}}"
ENV_NAME="${ENV_NAME:-cae-secretless-${SUFFIX}}"
API_NAME="${API_NAME:-ca-secretless-api-${SUFFIX}}"
CLIENT_NAME="${CLIENT_NAME:-ca-secretless-client-${SUFFIX}}"
IDENTITY_NAME="${IDENTITY_NAME:-id-secretless-acrpull-${SUFFIX}}"
API_KEY="${API_KEY:-$(python3 -c 'import uuid; print(uuid.uuid4())')}"

echo "Creating resource group and registry..."
az group create --name "$RG" --location "$LOCATION" -o none
az acr create --name "$ACR_NAME" --resource-group "$RG" --location "$LOCATION" \
  --sku Basic --admin-enabled false -o none

echo "Creating user-assigned identity and granting AcrPull..."
az identity create --name "$IDENTITY_NAME" --resource-group "$RG" --location "$LOCATION" -o none
IDENTITY_ID="$(az identity show --name "$IDENTITY_NAME" --resource-group "$RG" --query id -o tsv)"
IDENTITY_PRINCIPAL_ID="$(az identity show --name "$IDENTITY_NAME" --resource-group "$RG" --query principalId -o tsv)"
ACR_ID="$(az acr show --name "$ACR_NAME" --resource-group "$RG" --query id -o tsv)"
az role assignment create --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role AcrPull --scope "$ACR_ID" -o none

echo "Building images in ACR..."
az acr build --registry "$ACR_NAME" --image client:latest --file src/client/Dockerfile src/client -o none
az acr build --registry "$ACR_NAME" --image asset-api:latest --file src/api/Dockerfile src/api -o none

echo "Creating Container Apps environment..."
az containerapp env create --name "$ENV_NAME" --resource-group "$RG" --location "$LOCATION" -o none

REGISTRY_SERVER="${ACR_NAME}.azurecr.io"
API_IMAGE="${REGISTRY_SERVER}/asset-api:latest"
CLIENT_IMAGE="${REGISTRY_SERVER}/client:latest"

echo "Deploying API Container App..."
az containerapp create --name "$API_NAME" --resource-group "$RG" --environment "$ENV_NAME" \
  --image "$API_IMAGE" --target-port 8080 --ingress external --min-replicas 1 --max-replicas 1 \
  --user-assigned "$IDENTITY_ID" --registry-server "$REGISTRY_SERVER" \
  --registry-identity "$IDENTITY_ID" \
  --secrets asset-api-key="$API_KEY" \
  --env-vars ASSET_API_KEY=secretref:asset-api-key SQLITE_PATH=/data/assets.db -o none

API_FQDN="$(az containerapp show --name "$API_NAME" --resource-group "$RG" \
  --query properties.configuration.ingress.fqdn -o tsv)"
API_URL="https://${API_FQDN}/assets/search"

echo "Deploying client Container App..."
az containerapp create --name "$CLIENT_NAME" --resource-group "$RG" --environment "$ENV_NAME" \
  --image "$CLIENT_IMAGE" --target-port 8080 --ingress external --min-replicas 1 --max-replicas 1 \
  --user-assigned "$IDENTITY_ID" --registry-server "$REGISTRY_SERVER" \
  --registry-identity "$IDENTITY_ID" \
  --secrets asset-api-key="$API_KEY" \
  --env-vars ASSET_SERVICE_API_URL="$API_URL" ASSET_SERVICE_API_KEY=secretref:asset-api-key \
  APP_SECURITY_STAGE=container \
  -o none

CLIENT_FQDN="$(az containerapp show --name "$CLIENT_NAME" --resource-group "$RG" \
  --query properties.configuration.ingress.fqdn -o tsv)"

cat <<EOF
Deployment complete.
Resource group: $RG
Client URL: https://${CLIENT_FQDN}
Asset API URL: ${API_URL}
The generated GUID API key is stored in the API Container App secret and the client app setting.
EOF
