#!/usr/bin/env bash
# =============================================================================
# scripts/03-aro-prep-for-arc.sh
#
# OpenShift-specific preparation for connecting to Azure Arc.
#
# References:
#   - https://learn.microsoft.com/azure/azure-arc/kubernetes/quickstart-connect-cluster
#   - https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc
#
# Steps performed:
#   1. Verify we are logged in to the ARO cluster as cluster-admin.
#   2. Register Microsoft.Kubernetes / Microsoft.KubernetesConfiguration /
#      Microsoft.ExtendedLocation resource providers in the subscription.
#   3. Install (or update) the connectedk8s + k8s-extension Azure CLI extensions.
#   4. Grant the documented `privileged` SCC to the azure-arc proxy
#      ServiceAccount that az connectedk8s will create. This SCC binding must
#      exist BEFORE `az connectedk8s connect`; the proxy pod will otherwise be
#      blocked by OpenShift's default `restricted-v2` SCC and the connect
#      command will time out.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase D: OpenShift Arc prep"
echo "============================================="

# -----------------------------------------------
# 0. Preconditions
# -----------------------------------------------
require_azure_login

for cmd in oc az; do
    check_command "$cmd" || exit 1
done

if ! oc whoami &>/dev/null; then
    log_error "Not logged in to OpenShift. Run 'make oc-login' first."
    exit 1
fi

CURRENT_USER="$(oc whoami)"
log_info "Logged in to ARO as: ${CURRENT_USER}"

# Cluster-admin check (we will create cluster-scoped SCC bindings).
if ! oc auth can-i create clusterrolebindings --quiet; then
    log_error "Current user '${CURRENT_USER}' does not have cluster-admin. Run 'make oc-login' (uses kubeadmin)."
    exit 1
fi
log_ok "Cluster-admin verified."

# -----------------------------------------------
# 1. Register Azure resource providers
# -----------------------------------------------
log_info "Registering Azure resource providers (asynchronous, may take ~10 min)..."
for rp in Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.ExtendedLocation; do
    state=$(az provider show -n "$rp" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
    if [[ "$state" == "Registered" ]]; then
        log_ok "  $rp already Registered."
        continue
    fi
    log_info "  Registering $rp (current state: $state)..."
    az provider register --namespace "$rp" --output none
done

# Poll until all three are Registered (or 10 min timeout).
log_info "Waiting up to 10 min for resource providers to reach Registered..."
DEADLINE=$(( $(date +%s) + 600 ))
while true; do
    ALL_REG=1
    for rp in Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.ExtendedLocation; do
        state=$(az provider show -n "$rp" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
        if [[ "$state" != "Registered" ]]; then
            ALL_REG=0
            log_info "  $rp: $state"
        fi
    done
    if [[ $ALL_REG -eq 1 ]]; then
        log_ok "All resource providers Registered."
        break
    fi
    if [[ $(date +%s) -ge $DEADLINE ]]; then
        log_error "Timed out waiting for resource provider registration."
        exit 1
    fi
    sleep 20
done

# -----------------------------------------------
# 2. Install / update Azure CLI extensions
# -----------------------------------------------
log_info "Ensuring Azure CLI extensions are installed and current..."
for ext in connectedk8s k8s-extension; do
    if az extension show -n "$ext" &>/dev/null; then
        log_info "  Updating $ext..."
        az extension update -n "$ext" --output none 2>&1 | grep -v -E "^$" || true
    else
        log_info "  Installing $ext..."
        az extension add -n "$ext" --output none
    fi
done
log_ok "Azure CLI extensions ready."

# -----------------------------------------------
# 3. Pre-create the azure-arc namespace and grant privileged SCC
#
# Microsoft's docs (Arc troubleshooting) call out OpenShift specifically:
#   oc adm policy add-scc-to-user privileged \
#     system:serviceaccount:azure-arc:azure-arc-kube-aad-proxy-sa
#
# The SA is created by `az connectedk8s connect`, but applying the SCC
# binding ahead of time is idempotent and avoids a race where the proxy
# pod CrashLoops while SCC propagates.
# -----------------------------------------------
log_info "Creating azure-arc namespace (if absent)..."
if ! oc get ns azure-arc &>/dev/null; then
    oc create ns azure-arc
fi
log_ok "azure-arc namespace present."

log_info "Granting 'privileged' SCC to azure-arc-kube-aad-proxy-sa..."
SCC_USER="system:serviceaccount:azure-arc:azure-arc-kube-aad-proxy-sa"
# add-scc-to-user is idempotent.
oc adm policy add-scc-to-user privileged "$SCC_USER" >/dev/null
log_ok "SCC binding applied (documented Microsoft workaround for OpenShift + Arc)."

# Capture for the report.
progress_log "prep-arc" \
"OpenShift-specific divergence applied: granted \`privileged\` SCC to \
\`${SCC_USER}\`. Per [MS troubleshooting](https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc) \
this is required for the Arc aad-proxy pod to start on OpenShift."

mark_state prep-arc
log_ok "============================================="
log_ok " Arc prep complete. Next: make arc-connect"
log_ok "============================================="
