#!/usr/bin/env bash
# Prints the Application Gateway public URL for the final environment.
# Usage: bash infra/final/get-url.sh [--open]
#
# Pass --open to also open the URL in the default browser.
set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPEN_BROWSER="false"
for arg in "$@"; do
  [[ "$arg" == "--open" ]] && OPEN_BROWSER="true"
done

# Try the azd environment store first (fast, no Azure API call needed).
URL=""
if command -v azd &>/dev/null; then
  URL="$(azd env get-value APP_GATEWAY_URL --cwd "$STAGE_DIR" 2>/dev/null || true)"
  # Discard corrupt azd env values (error text stored as the value).
  [[ "$URL" == *"ERROR:"* || "$URL" == *$'\n'* ]] && URL=""
fi

if [[ -z "$URL" ]]; then
  echo "APP_GATEWAY_URL not in azd env; querying Azure..." >&2

  RG=""
  if command -v azd &>/dev/null; then
    RG="$(azd env get-value AZURE_RESOURCE_GROUP --cwd "$STAGE_DIR" 2>/dev/null || true)"
    [[ "$RG" == *"ERROR:"* || "$RG" == *$'\n'* ]] && RG=""
  fi
  RG="${AZURE_RESOURCE_GROUP:-$RG}"

  if [[ -z "$RG" ]]; then
    echo "ERROR: Could not determine resource group. Set AZURE_RESOURCE_GROUP or run 'azd up' first." >&2
    exit 1
  fi

  # Find the Application Gateway in the resource group.
  AGW_NAME="$(az network application-gateway list \
    --resource-group "$RG" \
    --query "[0].name" -o tsv 2>/dev/null || true)"

  if [[ -z "$AGW_NAME" ]]; then
    echo "ERROR: No Application Gateway found in resource group '$RG'." >&2
    exit 1
  fi

  PUBLIC_IP_NAME="$(az network application-gateway show \
    --resource-group "$RG" \
    --name "$AGW_NAME" \
    --query "frontendIPConfigurations[0].publicIPAddress.id" -o tsv 2>/dev/null | xargs basename 2>/dev/null || true)"

  if [[ -z "$PUBLIC_IP_NAME" ]]; then
    echo "ERROR: Could not find the public IP for Application Gateway '$AGW_NAME'." >&2
    exit 1
  fi

  FQDN="$(az network public-ip show \
    --resource-group "$RG" \
    --name "$PUBLIC_IP_NAME" \
    --query dnsSettings.fqdn -o tsv 2>/dev/null || true)"

  IP="$(az network public-ip show \
    --resource-group "$RG" \
    --name "$PUBLIC_IP_NAME" \
    --query ipAddress -o tsv 2>/dev/null || true)"

  HOST="${FQDN:-$IP}"
  if [[ -z "$HOST" ]]; then
    echo "ERROR: Application Gateway public IP has no address yet (still provisioning?)." >&2
    exit 1
  fi

  URL="http://${HOST}"

  # Persist back to the azd environment for next time.
  if command -v azd &>/dev/null; then
    azd env set APP_GATEWAY_URL "$URL" --cwd "$STAGE_DIR" >/dev/null 2>&1 || true
    azd env set API_URL "$URL" --cwd "$STAGE_DIR" >/dev/null 2>&1 || true
    [[ -n "$FQDN" ]] && azd env set APP_GATEWAY_FQDN "$FQDN" --cwd "$STAGE_DIR" >/dev/null 2>&1 || true
    [[ -n "$IP" ]] && azd env set APP_GATEWAY_IP "$IP" --cwd "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
fi

echo "$URL"

if [[ "$OPEN_BROWSER" == "true" ]]; then
  if command -v open &>/dev/null; then
    open "$URL"
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$URL"
  fi
fi
