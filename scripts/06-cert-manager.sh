#!/usr/bin/env bash
# =============================================================================
# scripts/06-cert-manager.sh
#
# Step 1 of the Foundry Local deploy doc: install the Microsoft.CertManagement
# Arc extension (cert-manager + trust-manager).
#
# Reference:
#   https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension#step-1-install-cert-manager-and-trust-manager
#
# OpenShift-specific guardrails:
#   - If the cluster already has cert-manager (e.g., from the "cert-manager
#     Operator for Red Hat OpenShift" via OperatorHub), the Arc extension's
#     CRDs would collide. We detect this and abort with guidance.
#   - cert-manager / trust-manager pods may be denied by OpenShift's default
#     restricted-v2 SCC. We watch for that and grant `nonroot-v2` to their
#     ServiceAccounts, then escalate to `anyuid` only if pods stay denied.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase G: cert-manager Arc extension"
echo "============================================="

require_azure_login

for cmd in az oc; do
    check_command "$cmd" || exit 1
done

EXTENSION_NAME="azure-cert-manager"

# -----------------------------------------------
# 1. Conflict detection: existing cert-manager on the cluster.
# -----------------------------------------------
log_info "Checking for pre-existing cert-manager CRDs on the cluster..."
EXISTING_CRDS=$(oc get crd -o name 2>/dev/null | grep -E '(cert-manager\.io|certmanager\.k8s\.io)' || true)
if [[ -n "$EXISTING_CRDS" ]]; then
    log_error "Pre-existing cert-manager CRDs detected:"
    echo "$EXISTING_CRDS" | sed 's/^/    /'
    log_error ""
    log_error "The Microsoft.CertManagement Arc extension owns these CRDs and would conflict."
    log_error "If this is the Red Hat 'cert-manager Operator for Red Hat OpenShift', uninstall it"
    log_error "(or pick a cluster without it). Aborting per AGENTS.md (destructive scope requires"
    log_error "operator confirmation)."
    progress_log "cert-manager" "ABORTED: pre-existing cert-manager CRDs detected. Manual intervention required."
    exit 1
fi
log_ok "No pre-existing cert-manager found."

# -----------------------------------------------
# 2. Install / update the extension.
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

    log_info "Installing Microsoft.CertManagement Arc extension (this can take 5-10 min)..."
    az k8s-extension create \
        --cluster-name "$ARC_CLUSTER_NAME" \
        --resource-group "$RESOURCEGROUP" \
        --cluster-type connectedClusters \
        --name "$EXTENSION_NAME" \
        --extension-type Microsoft.CertManagement \
        --scope cluster \
        --release-train stable \
        --config config.enableGatewayAPI=true \
        --config cert-manager.crds.keep=true \
        --config trust-manager.defaultPackage.enabled=false \
        --config trust-manager.secretTargets.enabled=true \
        --config trust-manager.secretTargets.authorizedSecretsAll=true \
        --output none
    log_ok "Extension create command returned."
fi

# -----------------------------------------------
# 3. Discover the release namespace the extension chose, then wait for pods.
# -----------------------------------------------
EXT_NS=$(az k8s-extension show \
    --cluster-name "$ARC_CLUSTER_NAME" \
    --resource-group "$RESOURCEGROUP" \
    --cluster-type connectedClusters \
    --name "$EXTENSION_NAME" \
    --query "scope.cluster.releaseNamespace" -o tsv 2>/dev/null || echo "cert-manager")
EXT_NS="${EXT_NS:-cert-manager}"
log_info "cert-manager release namespace: ${EXT_NS}"

# -----------------------------------------------
# 4. Apply SCC remediation if pods can't start.
#
# Strategy: wait 90s, then if any pods are not Running, try least-privileged
# SCC grants. We do not blindly apply SCCs upfront — first see if the
# extension works out of the box (the doc doesn't mention SCCs at all).
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

log_info "Waiting up to 5 min for cert-manager pods to reach Running..."
DEADLINE=$(( $(date +%s) + 300 ))
SCC_APPLIED=""
while true; do
    NOT_READY=$(oc -n "$EXT_NS" get pods --no-headers 2>/dev/null \
        | awk '$3!="Running" && $3!="Completed" { print $1 ":" $3 }' || true)
    TOTAL=$(oc -n "$EXT_NS" get pods --no-headers 2>/dev/null | wc -l)

    if [[ -z "$NOT_READY" ]] && [[ "$TOTAL" -gt 0 ]]; then
        log_ok "All cert-manager pods are Running."
        break
    fi

    if [[ $(date +%s) -ge $DEADLINE ]]; then
        log_warn "Pods still not Running after 5 min:"
        oc -n "$EXT_NS" get pods -o wide || true
        log_warn "Capturing diagnostics..."
        DIAG=$(oc -n "$EXT_NS" get pods -o wide 2>&1; \
               echo "---"; \
               oc -n "$EXT_NS" get events --sort-by=.lastTimestamp 2>&1 | tail -30)
        progress_log "cert-manager" "FAILED: cert-manager pods did not reach Running. Last state:
\`\`\`
${DIAG}
\`\`\`
SCC remediations attempted: ${SCC_APPLIED:-none}."
        exit 1
    fi

    # Check pod events for SCC denials and remediate incrementally. We
    # intentionally do not use --field-selector reason=FailedCreate — SCC
    # denials surface as Failed / FailedScheduling / FailedCreate depending
    # on whether the rejection comes from the Pod admission webhook or a
    # parent controller.
    SCC_DENIED=$(oc -n "$EXT_NS" get events 2>/dev/null \
        | grep -c -E 'SecurityContextConstraints|violates PodSecurity|unable to validate against any security context constraint' || true)
    if [[ "$SCC_DENIED" -gt 0 ]]; then
        if [[ -z "$SCC_APPLIED" ]]; then
            log_warn "Detected SCC denials. Applying 'nonroot-v2' as first remediation."
            apply_scc_to_namespace_sas "$EXT_NS" nonroot-v2
            SCC_APPLIED="nonroot-v2"
            sleep 15
            continue
        elif [[ "$SCC_APPLIED" == "nonroot-v2" ]]; then
            log_warn "Pods still blocked under 'nonroot-v2'. Escalating to 'anyuid'."
            apply_scc_to_namespace_sas "$EXT_NS" anyuid
            SCC_APPLIED="anyuid"
            sleep 15
            continue
        fi
    fi

    log_info "  ...waiting ($(echo "$NOT_READY" | tr '\n' ' '))"
    sleep 15
done

# -----------------------------------------------
# 5. Verify cert-manager CRDs registered.
# -----------------------------------------------
log_info "Verifying cert-manager CRDs..."
EXPECTED_CRDS=(certificates.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io)
for crd in "${EXPECTED_CRDS[@]}"; do
    if oc get crd "$crd" &>/dev/null; then
        log_ok "  $crd present"
    else
        log_error "  $crd missing"
        progress_log "cert-manager" "FAILED: expected CRD ${crd} not registered."
        exit 1
    fi
done

if [[ -n "$SCC_APPLIED" ]]; then
    progress_log "cert-manager" "Installed Microsoft.CertManagement in namespace \`${EXT_NS}\`. **OpenShift divergence**: needed SCC \`${SCC_APPLIED}\` for cert-manager ServiceAccounts — the doc does not mention this because it only validates against AKS."
else
    progress_log "cert-manager" "Installed Microsoft.CertManagement in namespace \`${EXT_NS}\`. No SCC remediation required."
fi

mark_state cert-manager
log_ok "============================================="
log_ok " cert-manager ready. Next: make ingress / make foundry-operator"
log_ok "============================================="
