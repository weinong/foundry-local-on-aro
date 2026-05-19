#!/usr/bin/env bash
# =============================================================================
# scripts/08-foundry-operator.sh
#
# Step 2 of the Foundry Local deploy doc: install the Microsoft.Foundry
# (inference operator) Arc extension.
#
# Reference:
#   https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension#step-2-install-the-inference-operator
#
# OpenShift remediations applied opportunistically:
#   - SCC grants for the operator's ServiceAccounts if pods are blocked by
#     OpenShift's default restricted-v2.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase I: Foundry inference operator extension"
echo "============================================="

require_azure_login

for cmd in az oc jq; do
    check_command "$cmd" || exit 1
done

if [[ ! -f "$FOUNDRY_APP_FILE" ]]; then
    log_error "Missing $FOUNDRY_APP_FILE. Run 'make entra-app' first."
    exit 1
fi

APP_TENANT_ID=$(jq -r .tenantId "$FOUNDRY_APP_FILE")
APP_CLIENT_ID=$(jq -r .appId    "$FOUNDRY_APP_FILE")
log_info "Using Entra app: tenant=${APP_TENANT_ID} clientId=${APP_CLIENT_ID}"

EXTENSION_NAME="inference-operator"

# -----------------------------------------------
# 1. Install / update the extension.
# -----------------------------------------------
EXT_STATE=$(az k8s-extension show \
    --cluster-name "$ARC_CLUSTER_NAME" \
    --resource-group "$RESOURCEGROUP" \
    --cluster-type connectedClusters \
    --name "$EXTENSION_NAME" \
    --query provisioningState -o tsv 2>/dev/null || echo "")

if [[ "$EXT_STATE" == "Succeeded" ]]; then
    log_ok "Extension '${EXTENSION_NAME}' already installed (provisioningState=Succeeded)."
else
    if [[ -n "$EXT_STATE" ]]; then
        log_warn "Extension exists but provisioningState='${EXT_STATE}'. Re-creating."
        az k8s-extension delete \
            --cluster-name "$ARC_CLUSTER_NAME" \
            --resource-group "$RESOURCEGROUP" \
            --cluster-type connectedClusters \
            --name "$EXTENSION_NAME" \
            --yes --force --output none || true
    fi

    log_info "Installing Microsoft.Foundry Arc extension..."
    az k8s-extension create \
        --resource-group "$RESOURCEGROUP" \
        --cluster-name "$ARC_CLUSTER_NAME" \
        --cluster-type connectedClusters \
        --name "$EXTENSION_NAME" \
        --extension-type Microsoft.Foundry \
        --scope cluster \
        --release-namespace "$FOUNDRY_NAMESPACE" \
        --auto-upgrade-minor-version true \
        --release-train stable \
        --config entraAuth.tenantId="$APP_TENANT_ID" \
        --config entraAuth.clientId="$APP_CLIENT_ID" \
        --output none
    log_ok "Extension create command returned."
fi

# -----------------------------------------------
# 2. Wait for operator pods, applying SCC remediation if needed.
# -----------------------------------------------
apply_scc_to_namespace_sas() {
    local ns="$1"
    local scc="$2"
    log_info "  Granting SCC '${scc}' to all ServiceAccounts in namespace '${ns}'..."
    local sa
    while read -r sa; do
        [[ -z "$sa" ]] && continue
        oc adm policy add-scc-to-user "$scc" "system:serviceaccount:${ns}:${sa}" >/dev/null || true
    done < <(oc -n "$ns" get sa --no-headers 2>/dev/null | awk '{print $1}')
}

log_info "Waiting up to 10 min for foundry-local-operator pods to reach Running..."
DEADLINE=$(( $(date +%s) + 600 ))
SCC_APPLIED=""
while true; do
    TOTAL=$(oc -n "$FOUNDRY_NAMESPACE" get pods --no-headers 2>/dev/null | wc -l)
    NOT_READY=$(oc -n "$FOUNDRY_NAMESPACE" get pods --no-headers 2>/dev/null \
        | awk '$3!="Running" && $3!="Completed" { print $1 ":" $3 }' || true)

    if [[ -z "$NOT_READY" ]] && [[ "$TOTAL" -gt 0 ]]; then
        log_ok "All foundry-local-operator pods are Running."
        break
    fi

    if [[ $(date +%s) -ge $DEADLINE ]]; then
        log_error "Operator pods did not reach Running in 10 min."
        DIAG=$(oc -n "$FOUNDRY_NAMESPACE" get pods -o wide 2>&1; \
               echo "---"; \
               oc -n "$FOUNDRY_NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 | tail -50; \
               echo "---"; \
               az k8s-extension show \
                   --cluster-name "$ARC_CLUSTER_NAME" \
                   --resource-group "$RESOURCEGROUP" \
                   --cluster-type connectedClusters \
                   --name "$EXTENSION_NAME" \
                   --query "{state:provisioningState, statuses:statuses}" -o json 2>&1)
        progress_log "foundry-operator" "FAILED: operator pods did not reach Running. SCC remediations attempted: ${SCC_APPLIED:-none}. Diagnostics:
\`\`\`
${DIAG}
\`\`\`"
        exit 1
    fi

    # SCC denial detection: don't filter by reason — denials can surface as
    # FailedCreate (controller), Failed (pod admission), or FailedScheduling
    # depending on which admission stage rejected the pod.
    SCC_DENIED=$(oc -n "$FOUNDRY_NAMESPACE" get events 2>/dev/null \
        | grep -c -E 'SecurityContextConstraints|violates PodSecurity|unable to validate against any security context constraint' || true)
    if [[ "$SCC_DENIED" -gt 0 ]]; then
        if [[ -z "$SCC_APPLIED" ]]; then
            log_warn "SCC denials in '${FOUNDRY_NAMESPACE}'. Applying 'nonroot-v2'."
            apply_scc_to_namespace_sas "$FOUNDRY_NAMESPACE" nonroot-v2
            SCC_APPLIED="nonroot-v2"
            sleep 15
            continue
        elif [[ "$SCC_APPLIED" == "nonroot-v2" ]]; then
            log_warn "Still blocked. Escalating to 'anyuid'."
            apply_scc_to_namespace_sas "$FOUNDRY_NAMESPACE" anyuid
            SCC_APPLIED="anyuid"
            sleep 15
            continue
        fi
    fi

    log_info "  ...waiting ($(echo "$NOT_READY" | tr '\n' ' '))"
    sleep 15
done

# -----------------------------------------------
# 3. Verify CRDs registered.
# -----------------------------------------------
log_info "Verifying Foundry Local CRDs..."
FOUNDRY_CRDS=$(oc get crd -o name | grep -i foundry || true)
if [[ -z "$FOUNDRY_CRDS" ]]; then
    log_error "No CRDs with 'foundry' in name found. Operator install may be incomplete."
    progress_log "foundry-operator" "FAILED: no Foundry CRDs registered after operator install."
    exit 1
fi
echo "$FOUNDRY_CRDS" | sed 's/^/    /'
log_ok "Foundry Local CRDs present."

# -----------------------------------------------
# 4. Show what's available in the catalog ConfigMap.
# -----------------------------------------------
log_info "Catalog ConfigMap summary:"
if oc -n "$FOUNDRY_NAMESPACE" get configmap foundry-local-catalog &>/dev/null; then
    MODEL_COUNT=$(oc get models -A --no-headers 2>/dev/null | wc -l)
    log_ok "  Found ${MODEL_COUNT} Model CRs after catalog sync."
else
    log_warn "  foundry-local-catalog ConfigMap not yet present (catalog sync may be in progress)."
fi

if [[ -n "$SCC_APPLIED" ]]; then
    progress_log "foundry-operator" "Installed Microsoft.Foundry in namespace \`${FOUNDRY_NAMESPACE}\`. **OpenShift divergence**: required SCC \`${SCC_APPLIED}\` for operator ServiceAccounts."
else
    progress_log "foundry-operator" "Installed Microsoft.Foundry in namespace \`${FOUNDRY_NAMESPACE}\`. No SCC remediation required."
fi

mark_state foundry-operator
log_ok "============================================="
log_ok " Foundry inference operator ready. Next: make validate"
log_ok "============================================="
