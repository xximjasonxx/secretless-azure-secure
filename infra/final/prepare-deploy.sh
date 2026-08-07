#!/usr/bin/env bash
set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID=""
APP_NAME=""

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
    return 1
  fi

  echo "ERROR: Multiple App Services found in '$rg'. Set AZURE_WEBAPP_NAME in this stage environment."
  exit 1
}

wait_for_public_health() {
  local health_url="$1"
  local status_code=""

  for _ in {1..24}; do
    status_code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 "$health_url" || true)"
    if [[ "$status_code" == "200" ]]; then
      echo "App Service public endpoint is reachable."
      return 0
    fi

    sleep 5
  done

  echo "WARNING: App Service public endpoint did not return 200 after reopening."
}

RG="$(resolve_value_or_default "${AZURE_RESOURCE_GROUP:-$(get_env_value AZURE_RESOURCE_GROUP || true)}" "")"
if [[ -z "$RG" ]]; then
  echo "Skipping App Service reopen: AZURE_RESOURCE_GROUP is not set yet."
  exit 0
fi

APP_NAME="$(resolve_value_or_default "${AZURE_WEBAPP_NAME:-}" "")"
if [[ -z "$APP_NAME" ]]; then
  APP_NAME="$(discover_webapp_name "$RG" || true)"
fi

if [[ -z "$APP_NAME" ]]; then
  echo "Skipping App Service reopen: no App Service found in resource group '$RG' yet."
  exit 0
fi

APP_ID="$(az webapp show --resource-group "$RG" --name "$APP_NAME" --query id -o tsv 2>/dev/null || true)"
if [[ -z "$APP_ID" ]]; then
  echo "Skipping App Service reopen: could not resolve App Service '$APP_NAME'."
  exit 0
fi

CURRENT_PUBLIC_NETWORK_ACCESS="$(az resource show --ids "$APP_ID" --query properties.publicNetworkAccess -o tsv 2>/dev/null || true)"

if [[ "$CURRENT_PUBLIC_NETWORK_ACCESS" == "Disabled" ]]; then
  echo "Temporarily reopening App Service public access for azd deploy..."
  az resource update \
    --ids "$APP_ID" \
    --set properties.publicNetworkAccess=Enabled \
    --only-show-errors \
    -o none

  wait_for_public_health "https://${APP_NAME}.azurewebsites.net/health"
else
  echo "App Service public access already open for azd deploy."
fi
