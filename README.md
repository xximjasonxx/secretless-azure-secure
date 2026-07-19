# Azure App Security Journey Demo (.NET 8 + azd + Bicep)

This repo now models a **three-stage security journey** for an asset operations web app:

1. **start** — intentionally less secure baseline (connection string + app setting API key, no Key Vault).
2. **step1** — move storage access to **Managed Identity + RBAC**.
3. **step2** — introduce **Key Vault + RBAC** and apply **private networking**.

The custom asset service is treated as an external dependency. A `404` from that service is acceptable in this demo and the app falls back to local sample assets.

---

## What the app does

- Serves a simple web UI at `/` for:
  - asset search
  - adding comments
  - creating tickets
- Stores comments/tickets in **Azure Table Storage**
- Calls an external asset API using an API key (`ASSET_SERVICE_API_KEY`)
- Supports both storage auth modes in one code path:
  - `STORAGE_CONNECTION_STRING` (start)
  - `STORAGE_TABLES_URI` + `DefaultAzureCredential` (step1/step2)

---

## Repository layout

```text
infra/
├── start/
│   ├── main.bicep
│   ├── main.parameters.json
│   └── modules/
│       ├── app-start.bicep
│       └── storage-start.bicep
├── step1/
│   └── apply.sh
└── step2/
    ├── apply.sh
    └── main.bicep
```

`azure.yaml` points azd infra to `infra/start`.

---

## Prerequisites

- Azure CLI
- Azure Developer CLI (`azd`)
- .NET SDK 8

```bash
az login
azd auth login
```

---

## Stage 0: Initial standup (`azd up`)

`infra/start/apply.sh` always uses the currently active `az account` subscription context.

Use existing RG:

```bash
azd env set AZURE_RESOURCE_GROUP rg-securetalk-poc-swc-mx01
chmod +x infra/start/apply.sh
./infra/start/apply.sh
```

If you want azd to create an RG automatically, set `AZURE_RESOURCE_GROUP` to empty:

```bash
azd env set AZURE_RESOURCE_GROUP ""
./infra/start/apply.sh
```

### `start` stage posture

- App Service is public
- Storage is public and app uses **connection string**
- API key is stored directly in App Service app settings
- Key Vault is not deployed yet
- No private endpoints, no App Gateway, no Bastion

---

## Stage 1: Managed Identity + RBAC for storage

Run:

```bash
chmod +x infra/step1/apply.sh
./infra/step1/apply.sh
```

What it changes:

- Enables system-assigned identity on App Service
- Assigns `Storage Table Data Contributor` on Storage account
- Switches storage mode to MI (`STORAGE_TABLES_URI`) and clears `STORAGE_CONNECTION_STRING`
- Leaves API key in plain App Service app settings (still intentionally insecure)

---

## Stage 2: Private networking

Run:

```bash
chmod +x infra/step2/apply.sh
./infra/step2/apply.sh
```

What it deploys and applies:

- VNet and subnets for:
  - Application Gateway WAF v2
  - Private Endpoints
  - Bastion
- Creates Key Vault and seeds `AssetServiceApiKey` from the current app setting value
- Assigns Key Vault RBAC:
  - `Key Vault Administrator` to object `61a37498-9ab6-43d2-b70f-706fd58274e7`
  - `Key Vault Secrets User` to the App Service managed identity
- Switches `ASSET_SERVICE_API_KEY` app setting to Key Vault reference syntax
- Private endpoints for:
  - App Service (`sites`)
  - Key Vault (`vault`)
  - Storage Table (`table`)
- Private DNS zones and VNet links:
  - `privatelink.azurewebsites.net`
  - `privatelink.vaultcore.azure.net`
  - `privatelink.table.core.windows.net`
- Locks public access:
  - App Service `publicNetworkAccess=Disabled`
  - Key Vault public access disabled + deny firewall default
  - Storage public access disabled + deny firewall default

---

## Validate app behavior

```bash
API_URL=$(azd env get-value API_URL)
curl -sS "$API_URL/health"
```

Expected: `ok`

Open the web app:

```bash
open "$API_URL"
```

If the external asset API is not implemented yet, search still works via local fallback and may show source messages that include `asset service 404` or `asset service unavailable`.

After `step2`, validate through Application Gateway instead of direct App Service:

```bash
APP_GATEWAY_URL=$(azd env get-value APP_GATEWAY_URL)
curl -sS "$APP_GATEWAY_URL/health"
open "$APP_GATEWAY_URL"
```

---

## Notes

- This demo is intentionally staged; not all controls are enabled at `start`.
- `azd up` only deploys the **start** template unless you change `azure.yaml`.
- `step1` and `step2` are explicit operator-applied transitions for your presentation flow.
- If subscription policy forces `allowSharedKeyAccess=false`, the app falls back to in-memory comment/ticket persistence in `start` stage.
- If re-running `step2` after Key Vault is already private, set `ASSET_SERVICE_API_KEY_VALUE=<actual-key>` before running `./infra/step2/apply.sh`.
- `step2` currently exposes Application Gateway over HTTP for demo simplicity; add TLS listener/certificate before production use.
- With current `step2` design, direct `azd deploy` to App Service is expected to fail unless you also private-link the `scm` endpoint.
