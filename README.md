# Azure App Security Journey Demo (.NET 8 + azd + Bicep)

This repo deploys a hardened asset operations web app with a separate authenticated Asset API.

---

## What the app does

- Serves a web UI at `/` for:
  - asset search
  - adding comments
  - creating tickets
- Stores comments/tickets in **Azure Table Storage**
- Calls an external asset API using `ASSET_SERVICE_API_KEY`
- Supports both storage auth modes:
  - `STORAGE_TABLES_URI` + `DefaultAzureCredential`

---

## Repository layout

```text
infra/
├── main.bicep
├── main.parameters.json
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

The repository has one azd deployment project: `infra/final`.

Default environments:
- The final deployment uses `AZURE_ENV_NAME=final` and defaults to `rg-securetalk-poc-swc-mx01-final`.

---

## Deployment

```bash
cd infra/final
azd up
APP_GATEWAY_URL=$(azd env get-value APP_GATEWAY_URL)
curl -sS "$APP_GATEWAY_URL/health"
open "$APP_GATEWAY_URL"
```

The client uses the separately deployed Asset API Container App. The current default is:

```text
https://ca-secretless-api-6fe0f895.wonderfulsand-209444ec.swedencentral.azurecontainerapps.io/assets/search
```

If the Asset API Container App is recreated and receives a different ingress hostname, update the
`assetServiceApiUrl` default in `infra/main.bicep` before running `azd up` for `final`.

`infra/final/apply.sh` now resolves the Application Gateway public endpoint and writes:
- `APP_GATEWAY_URL` (primary URL)
- `API_URL` (same value for compatibility with azd endpoint lookups)
- `APP_GATEWAY_FQDN` and `APP_GATEWAY_IP` when available

`infra/final` defaults to azd environment name `final` and resource group `rg-securetalk-poc-swc-mx01-final`.

---

## Final deployment

The final deployment provisions the base resources, deploys the client, then applies full hardening:

- Storage MI/RBAC configuration (`Storage Table Data Contributor` scoped to the `assetcomments` and `assettickets` tables)
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

- If subscription policy forces `allowSharedKeyAccess=false`, the client falls back to in-memory comment/ticket persistence.
- If re-running `final` after Key Vault is already private, pass the secret value as a one-time shell variable when you run `azd up` (do not persist it with `azd env set`):

```bash
cd infra/final
ASSET_SERVICE_API_KEY_VALUE='<actual-key>' azd up
```

- `infra/final` now also supports re-running `azd up` from outside the private network without that override; if the existing Key Vault secret cannot be read, the deploy preserves the current secret value instead of failing.
- `infra/final` uses a custom `up` workflow with supported `azd` steps, plus hooks: `prepare-deploy.sh` runs at `predeploy` to reopen App Service only when needed, and `apply.sh` runs at `postdeploy` to re-apply final hardening.

- `final` exposes Application Gateway over HTTPS using a runtime-generated self-signed demo certificate. Browsers will show a certificate warning.
