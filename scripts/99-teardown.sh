#!/usr/bin/env bash
# =============================================================================
# scripts/99-teardown.sh
#
# Destroy every Azure resource created by this project, in reverse dependency
# order. The Makefile's teardown target performs the interactive confirmation;
# we still echo what we're about to do.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase K: teardown"
echo "============================================="

require_azure_login

for cmd in az; do
    check_command "$cmd" || exit 1
done

# -----------------------------------------------
# 1. Delete Arc extensions (best effort).
# -----------------------------------------------
for ext in inference-operator azure-cert-manager; do
    if az k8s-extension show \
            --cluster-name "$ARC_CLUSTER_NAME" \
            --resource-group "$RESOURCEGROUP" \
            --cluster-type connectedClusters \
            --name "$ext" >/dev/null 2>&1; then
        log_info "Deleting extension '${ext}'..."
        az k8s-extension delete \
            --cluster-name "$ARC_CLUSTER_NAME" \
            --resource-group "$RESOURCEGROUP" \
            --cluster-type connectedClusters \
            --name "$ext" \
            --yes --force --output none || log_warn "  delete failed for ${ext}; continuing."
    else
        log_info "Extension '${ext}' not present, skipping."
    fi
done

# -----------------------------------------------
# 2. Disconnect cluster from Arc.
# -----------------------------------------------
if az connectedk8s show -g "$RESOURCEGROUP" -n "$ARC_CLUSTER_NAME" >/dev/null 2>&1; then
    log_info "Disconnecting Arc cluster '${ARC_CLUSTER_NAME}'..."
    # `delete` for connectedk8s does both Azure-side and on-cluster cleanup.
    az connectedk8s delete \
        -g "$RESOURCEGROUP" \
        -n "$ARC_CLUSTER_NAME" \
        --yes --force --output none || log_warn "  connectedk8s delete failed; continuing."
else
    log_info "Arc connectedCluster not present, skipping."
fi

# -----------------------------------------------
# 3. Delete the Entra app registration.
# -----------------------------------------------
if [[ -f "$FOUNDRY_APP_FILE" ]]; then
    APP_ID=$(jq -r .appId "$FOUNDRY_APP_FILE" 2>/dev/null || echo "")
    if [[ -n "$APP_ID" ]]; then
        log_info "Deleting Entra app registration '${APP_ID}'..."
        az ad app delete --id "$APP_ID" --output none || log_warn "  app delete failed; continuing."
    fi
    rm -f "$FOUNDRY_APP_FILE"
fi

# -----------------------------------------------
# 4. Delete the ARO cluster.
# -----------------------------------------------
if az aro show -g "$RESOURCEGROUP" -n "$CLUSTER" >/dev/null 2>&1; then
    log_info "Deleting ARO cluster '${CLUSTER}' (this takes ~30 min)..."
    az aro delete -g "$RESOURCEGROUP" -n "$CLUSTER" --yes --output none
else
    log_info "ARO cluster not present, skipping."
fi

# -----------------------------------------------
# 5. Delete the resource group (also cleans up MIs, VNet, role assignments
#    attached to resources inside the RG).
# -----------------------------------------------
if az group show -n "$RESOURCEGROUP" >/dev/null 2>&1; then
    log_info "Deleting resource group '${RESOURCEGROUP}'..."
    az group delete -n "$RESOURCEGROUP" --yes --no-wait --output none
    log_ok "Resource group deletion queued (async)."
fi

# -----------------------------------------------
# 6. Clean local state.
# -----------------------------------------------
log_info "Clearing local state (.state/, kubeconfig)..."
rm -f "${STATE_DIR}"/*.done
rm -f "$KUBECONFIG_FILE"
rm -f "$FOUNDRY_APP_FILE"

progress_log "teardown" "Tore down ARO cluster \`${CLUSTER}\`, Arc connectedCluster \`${ARC_CLUSTER_NAME}\`, Entra app, and resource group \`${RESOURCEGROUP}\` (RG deletion runs async)."
log_ok "============================================="
log_ok " Teardown complete."
log_ok "============================================="
