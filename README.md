# Azure App Security Journey Demo (.NET 8 + azd + Bicep)

This repo models a staged security journey for an asset operations web app:

1. **start** — intentionally less secure baseline (connection string + plain app setting API key, public endpoints).
2. **step1** — move storage access to **Managed Identity + RBAC**.
3. **final** — complete hardened posture (Key Vault reference + private endpoints + Application Gateway).

---

## What the app does

- Serves a web UI at `/` for:
  - asset search
  - adding comments
  - creating tickets
- Stores comments/tickets in **Azure Table Storage**
- Calls an external asset API using `ASSET_SERVICE_API_KEY`
- Supports both storage auth modes:
  - `STORAGE_CONNECTION_STRING` (start)
  - `STORAGE_TABLES_URI` + `DefaultAzureCredential` (step1/final)

---

## Repository layout

```text
infra/
├── start/
│   ├── azure.yaml
│   ├── main.bicep
│   ├── main.parameters.json
│   └── modules/
│       ├── app-start.bicep
│       └── storage-start.bicep
├── step1/
│   ├── azure.yaml
│   ├── apply.sh
│   └── azd/
│       ├── main.bicep
│       └── main.parameters.json
└── final/
    ├── azure.yaml
    ├── apply.sh
    └── main.bicep
```

---

## Prerequisites

- Azure CLI
- Azure Developer CLI (`azd`)
- .NET SDK 8

```bash
az login
azd auth login
```

Each stage is its own azd project. Run `azd up` from the stage folder.

Default environments:
- `infra/final` uses `AZURE_ENV_NAME=final` and defaults to `rg-securetalk-poc-swc-mx01-final`
- `infra/start` and `infra/step1` use `AZURE_ENV_NAME=demo` and default to `rg-securetalk-poc-swc-mx01`

---

## Required presentation order

Deploy and verify the complete hardened environment **first**, then run baseline stages.

1. Predeploy complete solution (`final`) first:

```bash
cd infra/final
azd up
APP_GATEWAY_URL=$(azd env get-value APP_GATEWAY_URL)
curl -sS "$APP_GATEWAY_URL/health"
open "$APP_GATEWAY_URL"
```

`infra/final` defaults to azd environment name `final` and resource group `rg-securetalk-poc-swc-mx01-final`.

2. Deploy baseline (`start`) for live walkthrough:

```bash
cd infra/start
azd up
```

3. Apply managed identity step (`step1`) for live walkthrough:

```bash
cd infra/step1
azd up
```

4. Reveal the predeployed hardened endpoint from item 1 (`APP_GATEWAY_URL` in `infra/final`).

---

## Stage details

### `start`

- App Service is public
- Storage is public and app uses **connection string**
- API key is stored directly in App Service app settings
- No Key Vault/private endpoints/Application Gateway

### `step1`

- Enables system-assigned identity on App Service
- Assigns `Storage Table Data Contributor` on Storage account
- Switches storage mode to MI (`STORAGE_TABLES_URI`) and clears `STORAGE_CONNECTION_STRING`
- API key remains in plain app setting

### `final`

`final` runs baseline provisioning/deploy first, then applies full hardening:

- Storage MI/RBAC configuration (`Storage Table Data Contributor`)
- Key Vault creation and secret seeding (`AssetServiceApiKey`)
- Key Vault RBAC:
  - `Key Vault Administrator` to `KEYVAULT_ADMIN_OBJECT_ID` (defaults to current Azure CLI principal)
  - `Key Vault Secrets User` to the App Service managed identity
- `ASSET_SERVICE_API_KEY` switched to Key Vault reference
- Private endpoints for:
  - App Service (`sites`)
  - Key Vault (`vault`)
  - Storage Table (`table`)
- Private DNS zones + links:
  - `privatelink.azurewebsites.net`
  - `privatelink.vaultcore.azure.net`
  - `privatelink.table.core.windows.net`
- App Gateway (default SKU `Standard_v2`, override with `AZURE_APP_GATEWAY_SKU`)
- Public access disabled on App Service, Key Vault, and Storage

---

## Notes

- This demo is intentionally staged; not all controls are enabled at `start`.
- If subscription policy forces `allowSharedKeyAccess=false`, `start` falls back to in-memory comment/ticket persistence.
- If re-running `final` after Key Vault is already private, pass the secret value as a one-time shell variable when you run `azd up` (do not persist it with `azd env set`):

```bash
cd infra/final
ASSET_SERVICE_API_KEY_VALUE='<actual-key>' azd up
```

- `final` exposes Application Gateway over HTTP for demo simplicity; add TLS listener/certificate before production use.
