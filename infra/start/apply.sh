#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CURRENT_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
CURRENT_SUBSCRIPTION_NAME="$(az account show --query name -o tsv)"
DEFAULT_LOCATION="swedencentral"

TARGET_ENVIRONMENT=""
TARGET_LOCATION=""
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
  arg="${ARGS[$i]}"
  case "$arg" in
    --subscription|--subscription=*|-s|-s=*)
      echo "ERROR: Do not pass --subscription. This script always uses the active az account context."
      exit 1
      ;;
    --environment)
      if (( i + 1 >= ${#ARGS[@]} )); then
        echo "ERROR: --environment flag requires a value."
        exit 1
      fi
      TARGET_ENVIRONMENT="${ARGS[$((i + 1))]}"
      ;;
    --environment=*)
      TARGET_ENVIRONMENT="${arg#--environment=}"
      ;;
    -e)
      if (( i + 1 >= ${#ARGS[@]} )); then
        echo "ERROR: -e flag requires a value."
        exit 1
      fi
      TARGET_ENVIRONMENT="${ARGS[$((i + 1))]}"
      ;;
    -e=*)
      TARGET_ENVIRONMENT="${arg#-e=}"
      ;;
    --location)
      if (( i + 1 >= ${#ARGS[@]} )); then
        echo "ERROR: --location flag requires a value."
        exit 1
      fi
      TARGET_LOCATION="${ARGS[$((i + 1))]}"
      ;;
    --location=*)
      TARGET_LOCATION="${arg#--location=}"
      ;;
    -l)
      if (( i + 1 >= ${#ARGS[@]} )); then
        echo "ERROR: -l flag requires a value."
        exit 1
      fi
      TARGET_LOCATION="${ARGS[$((i + 1))]}"
      ;;
    -l=*)
      TARGET_LOCATION="${arg#-l=}"
      ;;
  esac
done

AZD_ENV_ARGS=()
if [[ -n "$TARGET_ENVIRONMENT" ]]; then
  AZD_ENV_ARGS=(--environment "$TARGET_ENVIRONMENT")
fi

RESOURCE_GROUP="$(azd env get-value AZURE_RESOURCE_GROUP --cwd "$ROOT_DIR" "${AZD_ENV_ARGS[@]}" 2>/dev/null || true)"
LOCATION_FROM_ENV="$(azd env get-value AZURE_LOCATION --cwd "$ROOT_DIR" "${AZD_ENV_ARGS[@]}" 2>/dev/null || true)"
RESOURCE_GROUP_LOCATION="${TARGET_LOCATION:-${LOCATION_FROM_ENV:-$DEFAULT_LOCATION}}"

echo "Using Azure CLI context subscription: $CURRENT_SUBSCRIPTION_NAME ($CURRENT_SUBSCRIPTION_ID)"

if [[ -n "$RESOURCE_GROUP" ]]; then
  RG_EXISTS="$(az group exists --name "$RESOURCE_GROUP" --subscription "$CURRENT_SUBSCRIPTION_ID" -o tsv)"
  if [[ "$RG_EXISTS" != "true" ]]; then
    if [[ -z "$RESOURCE_GROUP_LOCATION" ]]; then
      echo "ERROR: AZURE_RESOURCE_GROUP '$RESOURCE_GROUP' does not exist and no location is configured."
      echo "Set AZURE_LOCATION in azd env or pass --location to this script."
      exit 1
    fi

    echo "Creating resource group '$RESOURCE_GROUP' in '$RESOURCE_GROUP_LOCATION'..."
    az group create \
      --name "$RESOURCE_GROUP" \
      --location "$RESOURCE_GROUP_LOCATION" \
      --subscription "$CURRENT_SUBSCRIPTION_ID" \
      --only-show-errors \
      -o none
  fi
fi

azd env set AZURE_SUBSCRIPTION_ID "$CURRENT_SUBSCRIPTION_ID" --cwd "$ROOT_DIR" "${AZD_ENV_ARGS[@]}" >/dev/null
azd up --cwd "$ROOT_DIR" --subscription "$CURRENT_SUBSCRIPTION_ID" "$@"
