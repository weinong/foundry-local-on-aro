#!/usr/bin/env bash
# =============================================================================
# scripts/04-arc-connect.sh
#
# Connect the ARO cluster to Azure Arc.
#
# Reference:
#   https://learn.microsoft.com/azure/azure-arc/kubernetes/quickstart-connect-cluster
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase E: Connect ARO to Azure Arc"
echo "============================================="

require_azure_login

for cmd in az oc kubectl; do
    check_command "$cmd" || exit 1
done

if ! oc whoami &>/dev/null; then
    log_error "Not logged in to OpenShift. Run 'make oc-login' first."
    exit 1
fi

# -----------------------------------------------
# 1. Skip if already connected (idempotent)
# -----------------------------------------------
EXISTING=$(az connectedk8s show -g "$RESOURCEGROUP" -n "$ARC_CLUSTER_NAME" \
    --query connectivityStatus -o tsv 2>/dev/null || echo "")
if [[ "$EXISTING" == "Connected" ]]; then
    log_ok "Arc connectedCluster '${ARC_CLUSTER_NAME}' is already Connected. Skipping connect."
else
    if [[ -n "$EXISTING" ]]; then
        log_warn "connectedCluster '${ARC_CLUSTER_NAME}' exists with status='${EXISTING}'. Re-running connect."
    fi

    # -----------------------------------------------
    # 2. az connectedk8s connect
    # -----------------------------------------------
    log_info "Running az connectedk8s connect (this can take several minutes)..."
    log_info "  Resource group : $RESOURCEGROUP"
    log_info "  Location       : $LOCATION"
    log_info "  Cluster name   : $ARC_CLUSTER_NAME"

    # connect uses the current kubectl context. env.sh exports KUBECONFIG.
    az connectedk8s connect \
        --resource-group "$RESOURCEGROUP" \
        --name "$ARC_CLUSTER_NAME" \
        --location "$LOCATION" \
        --output table
fi

# -----------------------------------------------
# 3. Verify azure-arc agent pods
# -----------------------------------------------
log_info "Waiting for azure-arc agent pods to reach Running..."
DEADLINE=$(( $(date +%s) + 600 ))
while true; do
    # Count pods not yet in Running/Completed.
    NOT_READY=$(oc -n azure-arc get pods --no-headers 2>/dev/null \
        | awk '$3!="Running" && $3!="Completed" { print $1 }' || true)
    if [[ -z "$NOT_READY" ]] && [[ "$(oc -n azure-arc get pods --no-headers 2>/dev/null | wc -l)" -gt 0 ]]; then
        log_ok "All azure-arc pods are Running."
        break
    fi
    if [[ $(date +%s) -ge $DEADLINE ]]; then
        log_error "Timed out waiting for azure-arc pods. Current state:"
        oc -n azure-arc get pods -o wide || true
        log_error "Captured diagnostics — see docs/progress.md"
        DIAG=$(oc -n azure-arc get pods -o wide 2>&1; \
               echo "---"; \
               oc -n azure-arc get events --sort-by=.lastTimestamp 2>&1 | tail -30)
        progress_log "arc-connect" "FAILED: azure-arc pods did not reach Running within 10 min. Diagnostics:
\`\`\`
${DIAG}
\`\`\`"
        exit 1
    fi
    sleep 15
    log_info "  ...waiting (not yet ready: $(echo "$NOT_READY" | tr '\n' ' '))"
done

# -----------------------------------------------
# 4. Verify Arc resource in Azure
# -----------------------------------------------
log_info "Verifying connectedCluster resource in Azure..."
STATUS=$(az connectedk8s show -g "$RESOURCEGROUP" -n "$ARC_CLUSTER_NAME" \
    --query connectivityStatus -o tsv)
DISTRO=$(az connectedk8s show -g "$RESOURCEGROUP" -n "$ARC_CLUSTER_NAME" \
    --query distribution -o tsv 2>/dev/null || echo "unknown")
K8S_VER=$(az connectedk8s show -g "$RESOURCEGROUP" -n "$ARC_CLUSTER_NAME" \
    --query kubernetesVersion -o tsv 2>/dev/null || echo "unknown")
AGENT_VER=$(az connectedk8s show -g "$RESOURCEGROUP" -n "$ARC_CLUSTER_NAME" \
    --query agentVersion -o tsv 2>/dev/null || echo "unknown")

log_ok "Arc connectedCluster status:"
log_ok "  connectivityStatus = $STATUS"
log_ok "  distribution       = $DISTRO"
log_ok "  kubernetesVersion  = $K8S_VER"
log_ok "  agentVersion       = $AGENT_VER"

if [[ "$STATUS" != "Connected" ]]; then
    log_error "connectedCluster reports status='$STATUS', expected 'Connected'."
    exit 1
fi

progress_log "arc-connect" "Cluster \`${ARC_CLUSTER_NAME}\` is **Connected** to Arc. distribution=\`${DISTRO}\`, k8s=\`${K8S_VER}\`, agentVersion=\`${AGENT_VER}\`."

mark_state arc-connect
log_ok "============================================="
log_ok " Arc connect complete. Next: make entra-app"
log_ok "============================================="
