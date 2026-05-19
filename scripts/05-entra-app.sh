#!/usr/bin/env bash
# =============================================================================
# scripts/05-entra-app.sh
#
# Create a Microsoft Entra ID app registration for Foundry Local authentication,
# then perform the RBAC steps from the auth doc that involve the Arc
# connectedCluster identity.
#
# Reference:
#   https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/how-to-configure-authentication
#
# Doc steps covered here:
#   1. Register the app (single-tenant).
#   2. Expose an API with `api://<client-id>` URI and a `foundry_access`
#      delegated scope (admin consent).
#   3. Set accessTokenAcceptedVersion=2 in the manifest.
#   4. Add the Azure CLI as an authorized client application for that scope.
#   6. Assign 'Cognitive Services OpenAI User' to the Arc cluster's identity
#      scoped to the connectedCluster (avoids rbac_check_unavailable).
#
# Doc Step 5 (assign roles to end users) is left to the operator: we don't
# know which users they want to grant inference access to. We print the
# command they should run.
#
# Output:
#   ${FOUNDRY_APP_FILE}  (gitignored) — JSON with appId, tenantId, objectId,
#                                       scope, applicationIdUri.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase F: Entra app registration"
echo "============================================="

require_azure_login

for cmd in az jq python3; do
    check_command "$cmd" || exit 1
done

TENANT_ID=$(az account show --query tenantId -o tsv)
log_info "Tenant ID:      ${TENANT_ID}"
log_info "App reg name:   ${FOUNDRY_APP_NAME}"

# Azure CLI's well-known client ID (Microsoft public client).
AZ_CLI_CLIENT_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"
SCOPE_NAME="foundry_access"
SCOPE_DISPLAY_NAME="Access Foundry Local inference endpoints"
SCOPE_DESCRIPTION="Allows the application to access Foundry Local inference endpoints on behalf of the signed-in user"

# -----------------------------------------------
# Step 1: Create (or look up) the app registration.
# -----------------------------------------------
APP_ID=$(az ad app list --display-name "$FOUNDRY_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")
if [[ -n "$APP_ID" ]]; then
    log_ok "App registration '${FOUNDRY_APP_NAME}' already exists (appId=${APP_ID})."
else
    log_info "Creating app registration '${FOUNDRY_APP_NAME}' (single tenant)..."
    APP_ID=$(az ad app create \
        --display-name "$FOUNDRY_APP_NAME" \
        --sign-in-audience AzureADMyOrg \
        --query appId -o tsv)
    log_ok "Created appId=${APP_ID}."
fi

OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)
APP_URI="api://${APP_ID}"

# -----------------------------------------------
# Step 2 + 3: Expose an API + scope + token v2 (single PATCH).
#
# We build the full `api` block and PATCH it onto the application object
# using Microsoft Graph. `az ad app update --identifier-uris` only sets the
# URI; oauth2PermissionScopes and accessTokenAcceptedVersion live under `api`
# on the v1.0 application resource, so a single PATCH keeps them consistent.
#
# Step 4 (Azure CLI preauthorization) is a SEPARATE PATCH because Graph
# validates `api.preAuthorizedApplications.delegatedPermissionIds` against
# the *currently persisted* set of scope IDs. Putting the new scope and the
# preauth that references it in the same PATCH fails with:
#   "InvalidValue: Property api.preAuthorizedApplications.delegatedPermissionIds
#    has a Permission Id that cannot be found in the AppPermissions sets."
# -----------------------------------------------
log_info "Configuring app: api://, scope, v2 tokens..."

# Preserve any existing scope GUID if one already exists for foundry_access,
# otherwise mint a new one. Re-using the GUID keeps consents stable.
EXISTING_SCOPE_ID=$(az ad app show --id "$APP_ID" \
    --query "api.oauth2PermissionScopes[?value=='${SCOPE_NAME}'].id | [0]" -o tsv 2>/dev/null || echo "")
SCOPE_ID="${EXISTING_SCOPE_ID:-$(python3 -c 'import uuid;print(uuid.uuid4())')}"

if [[ -z "$SCOPE_ID" || ! "$SCOPE_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    log_error "Failed to obtain a scope GUID (got: '${SCOPE_ID}')."
    exit 1
fi

export APP_ID SCOPE_ID AZ_CLI_CLIENT_ID SCOPE_NAME SCOPE_DISPLAY_NAME SCOPE_DESCRIPTION

API_PATCH=$(python3 - <<'PY'
import json, os
app_id = os.environ["APP_ID"]
scope_id = os.environ["SCOPE_ID"]
patch = {
    "identifierUris": [f"api://{app_id}"],
    "api": {
        "acceptMappedClaims": None,
        "knownClientApplications": [],
        "requestedAccessTokenVersion": 2,
        "oauth2PermissionScopes": [{
            "id": scope_id,
            "adminConsentDescription": os.environ["SCOPE_DESCRIPTION"],
            "adminConsentDisplayName": os.environ["SCOPE_DISPLAY_NAME"],
            "isEnabled": True,
            "type": "Admin",
            "userConsentDescription": None,
            "userConsentDisplayName": None,
            "value": os.environ["SCOPE_NAME"]
        }]
    }
}
print(json.dumps(patch))
PY
)

# `az rest` to PATCH /applications/{objectId}. The az ad app update CLI does
# not expose api.requestedAccessTokenVersion.
az rest --method PATCH \
    --url "https://graph.microsoft.com/v1.0/applications/${OBJECT_ID}" \
    --headers "Content-Type=application/json" \
    --body "$API_PATCH" \
    --output none

log_ok "App configured: api://${APP_ID}, scope=${SCOPE_NAME}, accessTokenAcceptedVersion=2."

# Step 4: separate PATCH to preauthorize the Azure CLI for the foundry_access
# scope (Graph rejects this in the same PATCH that creates the scope).
log_info "Preauthorizing the Azure CLI client for scope '${SCOPE_NAME}'..."
PREAUTH_PATCH=$(python3 - <<'PY'
import json, os
azcli_id = os.environ["AZ_CLI_CLIENT_ID"]
scope_id = os.environ["SCOPE_ID"]
patch = {
    "api": {
        "preAuthorizedApplications": [{
            "appId": azcli_id,
            "delegatedPermissionIds": [scope_id]
        }]
    }
}
print(json.dumps(patch))
PY
)
az rest --method PATCH \
    --url "https://graph.microsoft.com/v1.0/applications/${OBJECT_ID}" \
    --headers "Content-Type=application/json" \
    --body "$PREAUTH_PATCH" \
    --output none
log_ok "Azure CLI preauthorized."

# -----------------------------------------------
# Step 6 (auth doc): assign 'Cognitive Services OpenAI User' to the Arc
# connectedCluster's own managed identity, scoped to the connectedCluster
# resource. Without this, every authenticated call returns 500
# rbac_check_unavailable.
# -----------------------------------------------
log_info "Looking up Arc connectedCluster identity..."
ARC_PRINCIPAL_ID=$(az connectedk8s show \
    -g "$RESOURCEGROUP" \
    -n "$ARC_CLUSTER_NAME" \
    --query "identity.principalId" -o tsv 2>/dev/null || echo "")

if [[ -z "$ARC_PRINCIPAL_ID" ]]; then
    log_error "Could not read identity.principalId from connectedCluster '${ARC_CLUSTER_NAME}'."
    log_error "Has 'make arc-connect' completed?"
    exit 1
fi
log_ok "Arc identity principalId: ${ARC_PRINCIPAL_ID}"

CC_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCEGROUP}/providers/Microsoft.Kubernetes/connectedClusters/${ARC_CLUSTER_NAME}"
log_info "Assigning 'Cognitive Services OpenAI User' to Arc identity, scoped to the connectedCluster..."
# az role assignment create is not idempotent — it errors on duplicates.
# Use list+check.
EXISTING_RA=$(az role assignment list \
    --assignee "$ARC_PRINCIPAL_ID" \
    --role "Cognitive Services OpenAI User" \
    --scope "$CC_SCOPE" \
    --query "[0].id" -o tsv 2>/dev/null || echo "")
if [[ -n "$EXISTING_RA" ]]; then
    log_ok "  Role assignment already exists."
else
    az role assignment create \
        --assignee-object-id "$ARC_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "Cognitive Services OpenAI User" \
        --scope "$CC_SCOPE" \
        --output none
    log_ok "  Role assignment created."
fi

# -----------------------------------------------
# Persist outputs to a gitignored JSON file consumed by 08-foundry-operator.sh
# and 09-validate.sh.
# -----------------------------------------------
umask 077
cat > "$FOUNDRY_APP_FILE" <<JSON
{
  "appName": "${FOUNDRY_APP_NAME}",
  "appId": "${APP_ID}",
  "objectId": "${OBJECT_ID}",
  "tenantId": "${TENANT_ID}",
  "applicationIdUri": "${APP_URI}",
  "scopeName": "${SCOPE_NAME}",
  "scopeId": "${SCOPE_ID}",
  "arcPrincipalId": "${ARC_PRINCIPAL_ID}",
  "connectedClusterScope": "${CC_SCOPE}"
}
JSON
chmod 600 "$FOUNDRY_APP_FILE"
log_ok "Wrote $(basename "$FOUNDRY_APP_FILE")"

echo ""
log_info "To grant a user inference access (Step 5 of the auth doc), run e.g.:"
echo "  az role assignment create \\"
echo "    --assignee \"<USER_OR_GROUP_OBJECT_ID>\" \\"
echo "    --role 'Cognitive Services OpenAI User' \\"
echo "    --scope \"${CC_SCOPE}\""
echo ""

# For 'validate' to call the endpoint as the current user, the operator
# themselves needs Cognitive Services OpenAI User. We don't grant this here
# automatically because it requires Owner or User Access Administrator on
# the scope — but it's a useful default if the operator already has that.
CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
if [[ -n "$CURRENT_USER_OID" ]]; then
    EXISTING_USER_RA=$(az role assignment list \
        --assignee "$CURRENT_USER_OID" \
        --role "Cognitive Services OpenAI User" \
        --scope "$CC_SCOPE" \
        --query "[0].id" -o tsv 2>/dev/null || echo "")
    if [[ -n "$EXISTING_USER_RA" ]]; then
        log_ok "Signed-in user already has 'Cognitive Services OpenAI User' on connectedCluster."
    else
        log_info "Granting 'Cognitive Services OpenAI User' to the signed-in user for validation..."
        if az role assignment create \
            --assignee-object-id "$CURRENT_USER_OID" \
            --assignee-principal-type User \
            --role "Cognitive Services OpenAI User" \
            --scope "$CC_SCOPE" \
            --output none 2>/dev/null; then
            log_ok "  Granted."
        else
            log_warn "  Could not self-assign role (likely missing UAA/Owner). Have an admin do it."
        fi
    fi
fi

progress_log "entra-app" "Created/updated app registration \`${FOUNDRY_APP_NAME}\` (appId \`${APP_ID}\`, scope \`${SCOPE_NAME}\`, token v2). Granted Arc identity \`${ARC_PRINCIPAL_ID}\` the \`Cognitive Services OpenAI User\` role on the connectedCluster."

mark_state entra-app
log_ok "============================================="
log_ok " Entra app ready. Next: make cert-manager"
log_ok "============================================="
