# Secretless Conference Talk Track (short)

## Slide 1 - Managed identity and token flow
1. Hit `/demo`.
2. Show response says `DefaultAzureCredential` and identity type.
3. Call out that app settings only contain `KEYVAULT_URI` and `STORAGE_BLOB_URI` (identifiers, not secrets).

## Slide 2 - Least privilege by dependency
1. Open `infra/modules/rbac.bicep`.
2. Point to:
   - Key Vault Secrets User
   - Storage Blob Data Reader
3. Say: "One narrow data-plane role per dependency, scoped to that resource."
4. Say: "Contributor is control-plane and would not read data here."

## Slide 3 - Private Endpoints and DNS
1. Open `infra/modules/privatedns.bicep`.
2. Show `privatelink.vaultcore.azure.net` and `privatelink.blob.core.windows.net`.
3. Explain: with VNet links + `vnetRouteAllEnabled`, public FQDN resolves to private IP path.
4. If needed, break DNS link temporarily and show `/demo` network error category.

## Slide 4 - Auto vs manual approval flow
1. Show auto flow from `privateLinkServiceConnections` in main deployment.
2. Deploy `infra/manual-approval-demo.bicep`.
3. Show connection state = `Pending`.
4. Approve with:
   `az network private-endpoint-connection approve --id <connection-id> --description "Approved on stage"`
5. Emphasize approval is RBAC-action-driven, not a generic network switch.

## Slide 5 - Lockdown proof
1. Toggle public network access on/off for Key Vault and Storage.
2. Re-hit `/demo`.
3. Narrate clear app failure categories:
   - 403 => auth/RBAC
   - network category => DNS/Private Link path issue

## Slide 6 - Cleanup
1. Run `azd down --purge`.
2. Confirm everything is removed in one command.
