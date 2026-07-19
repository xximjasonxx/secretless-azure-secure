#!/usr/bin/env bash
set -euo pipefail

STAGE_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_DIR="$SCRIPT_DIR/start"
ENV_NAME="${AZURE_ENV_NAME:-}"

if [[ -z "$ENV_NAME" ]]; then
  echo "ERROR: AZURE_ENV_NAME is not set for this stage."
  exit 1
fi

read_start_value() {
  local key="$1"
  azd env get-value "$key" --cwd "$START_DIR" --environment "$ENV_NAME" 2>/dev/null || true
}

set_stage_value() {
  local key="$1"
  local value="$2"
  azd env set "$key" "$value" --cwd "$STAGE_DIR" --environment "$ENV_NAME" >/dev/null
}

START_RG="$(read_start_value AZURE_RESOURCE_GROUP)"
START_LOCATION="$(read_start_value AZURE_LOCATION)"

if [[ -z "$START_RG" || -z "$START_LOCATION" ]]; then
  echo "ERROR: Could not read AZURE_RESOURCE_GROUP/AZURE_LOCATION from infra/start environment '$ENV_NAME'."
  echo "Run Stage 1 first from infra/start with the same environment name."
  exit 1
fi

set_stage_value AZURE_RESOURCE_GROUP "$START_RG"
set_stage_value AZURE_LOCATION "$START_LOCATION"

for key in AZURE_WEBAPP_NAME AZURE_STORAGE_ACCOUNT_NAME API_URL ASSET_COMMENTS_TABLE ASSET_TICKETS_TABLE; do
  value="$(read_start_value "$key")"
  if [[ -n "$value" ]]; then
    set_stage_value "$key" "$value"
  fi
done

echo "Synced stage environment from infra/start ($ENV_NAME)."
