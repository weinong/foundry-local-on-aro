#!/usr/bin/env bash
# =============================================================================
# scripts/06-cert-manager.sh
#
# Foundry Local deploy doc, Step 1: install cert-manager and trust-manager.
#
# Reference (the Microsoft-recommended path):
#   https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension#step-1-install-cert-manager-and-trust-manager
#
# *** OpenShift divergence from the AKS doc ***
#
# The doc tells you to install the `Microsoft.CertManagement` Arc extension,
# which bundles cert-manager v1.20.1 + trust-manager + an internal otel-collector
# sidecar. On Azure Red Hat OpenShift that extension fails to install for THREE
# independent reasons, all of which are baked into Microsoft's helm chart and
# its images:
#
# 1. The chart's pods use `hostPath` volumes. Only the `hostmount-anyuid`,
#    `hostaccess`, and `privileged` SCCs allow hostPath. The default
#    `restricted-v2` (used by all namespaces) denies them.
# 2. The chart's pods carry `seccomp.security.alpha.kubernetes.io/pod` and
#    `container.seccomp.security.alpha.kubernetes.io/*` annotations (the
#    Kubernetes-1.18-deprecated form). OpenShift's SCC admission rejects any
#    SCC except `privileged` when these annotations are present
#    ("seccomp may not be set").
# 3. The chart's otel-collector sidecar image
#    `mcr.microsoft.com/azuremonitor/opentelemetry-collector-internal:v0.143.3`
#    is published as a **nested OCI index** (a manifest list whose entries are
#    themselves manifest lists). CRI-O — OpenShift's container runtime — does
#    not implement nested-index resolution and refuses to pull the image with:
#       "Unexpectedly received a manifest list instead of a manifest for a
#        single image; Treating manifest lists as individual manifests is not
#        implemented"
#    Even granting `privileged` SCC doesn't fix this; the image cannot pull.
# 4. The helm install uses `--atomic`, so when any pod fails to schedule the
#    extension rolls back atomically and there is no window in which to patch
#    deployments.
#
# Workaround used here:
#   Install upstream cert-manager and trust-manager directly via helm. The
#   Foundry Local extension only requires the cert-manager.io and
#   trust.cert-manager.io API surfaces; it does not depend on Microsoft's
#   private otel-collector sidecar or other extension-private resources.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase G: cert-manager + trust-manager (upstream)"
echo "============================================="

require_azure_login

for cmd in oc helm; do
    check_command "$cmd" || exit 1
done

NS="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CM_VERSION="${CERT_MANAGER_VERSION:-v1.20.1}"
TM_VERSION="${TRUST_MANAGER_VERSION:-v0.20.1}"

# -----------------------------------------------
# 1. Detect any foreign cert-manager (Red Hat operator) and abort.
# -----------------------------------------------
log_info "Checking for pre-existing cert-manager CRDs on the cluster..."
FOREIGN=""
for crd in $(oc get crd -o name 2>/dev/null | grep -E '(cert-manager\.io|trust\.cert-manager\.io)' || true); do
    olm_label=$(oc get "$crd" -o jsonpath='{.metadata.labels.operators\.coreos\.com/cert-manager-operator\.cert-manager-operator}' 2>/dev/null || true)
    instance=$(oc get "$crd" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null || true)
    if [[ -n "$olm_label" ]]; then
        log_warn "  ${crd}: Red Hat cert-manager Operator (foreign)."
        FOREIGN="${FOREIGN}\n  ${crd}"
    elif [[ "$instance" == "cert-manager" || "$instance" == "trust-manager" ]]; then
        log_info "  ${crd}: from a previous upstream helm install (OK to keep)."
    else
        log_info "  ${crd}: present, will be re-managed by upstream chart."
    fi
done
if [[ -n "$FOREIGN" ]]; then
    log_error "Foreign cert-manager CRDs detected:"
    printf '%b\n' "$FOREIGN" | sed 's/^/    /'
    log_error "Resolve before continuing (uninstall the Red Hat operator first)."
    progress_log "cert-manager" "ABORTED: Red Hat cert-manager Operator detected."
    exit 1
fi
log_ok "No foreign cert-manager found."

# -----------------------------------------------
# 2. Add the upstream Jetstack helm repo.
# -----------------------------------------------
log_info "Adding upstream jetstack helm repo..."
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo update jetstack >/dev/null
log_ok "Helm repo ready."

# -----------------------------------------------
# 3. Namespace + SCC pre-grant.
#
# The upstream chart's default pod spec is OpenShift-restricted-v2 compatible
# (runAsNonRoot, no hostPath in default values, seccompProfile via spec
# field). But trust-manager mounts the kubelet CA via a default *projected*
# volume that does not need hostPath. Granting `nonroot-v2` is sufficient
# for normal operation; if the chart's RBAC for cluster-scoped Certificates
# tries to act-as cluster-admin, the namespace's restricted SCC may still
# block — we apply nonroot-v2 first and escalate to anyuid only on demand.
# -----------------------------------------------
if ! oc get ns "$NS" &>/dev/null; then
    log_info "Creating namespace '${NS}'..."
    oc create ns "$NS"
fi
log_info "Granting 'nonroot-v2' SCC to ServiceAccounts in '${NS}'..."
oc adm policy add-scc-to-group nonroot-v2 "system:serviceaccounts:${NS}" >/dev/null
log_ok "SCC pre-grant applied."

# -----------------------------------------------
# 4. Install cert-manager (upstream).
# -----------------------------------------------
log_info "Installing cert-manager ${CM_VERSION} via helm..."
helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "$NS" \
    --version "$CM_VERSION" \
    --set crds.enabled=true \
    --set crds.keep=true \
    --set installCRDs=false \
    --wait --timeout 10m

# -----------------------------------------------
# 5. Install trust-manager (upstream).
# -----------------------------------------------
log_info "Installing trust-manager ${TM_VERSION} via helm..."
helm upgrade --install trust-manager jetstack/trust-manager \
    --namespace "$NS" \
    --version "$TM_VERSION" \
    --set crds.enabled=true \
    --set crds.keep=true \
    --set secretTargets.enabled=true \
    --set secretTargets.authorizedSecretsAll=true \
    --set defaultPackage.enabled=false \
    --wait --timeout 10m

# -----------------------------------------------
# 6. Verify pods + CRDs.
# -----------------------------------------------
log_info "Verifying cert-manager + trust-manager pods..."
oc -n "$NS" get pods -o wide

NOT_READY=$(oc -n "$NS" get pods --no-headers \
    | awk '$3!="Running" && $3!="Completed" { print $1 }' || true)
if [[ -n "$NOT_READY" ]]; then
    log_error "Some pods are not Running:"
    echo "$NOT_READY"
    DIAG=$(oc -n "$NS" get pods -o wide 2>&1; \
           echo "---"; \
           oc -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -30)
    progress_log "cert-manager" "FAILED: upstream cert-manager pods not Running. Diagnostics:
\`\`\`
${DIAG}
\`\`\`"
    exit 1
fi
log_ok "All cert-manager + trust-manager pods are Running."

log_info "Verifying CRDs..."
for crd in certificates.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io bundles.trust.cert-manager.io; do
    if oc get crd "$crd" &>/dev/null; then
        log_ok "  $crd present"
    else
        log_error "  $crd missing"
        exit 1
    fi
done

progress_log "cert-manager" "Installed **upstream** cert-manager \`${CM_VERSION}\` and trust-manager \`${TM_VERSION}\` via Jetstack helm chart, bypassing the Microsoft.CertManagement Arc extension. **OpenShift divergence #3** (three sub-issues): the extension's chart uses (a) hostPath volumes, (b) deprecated \`seccomp.security.alpha.kubernetes.io/*\` annotations, and (c) an otel-collector sidecar image packaged as a nested OCI index that CRI-O cannot pull. None of these can be worked around with SCC bindings or namespace labels alone. Granted \`nonroot-v2\` SCC to ServiceAccounts in \`${NS}\` to satisfy the upstream chart's pod security context. The Foundry Local inference operator only depends on the \`cert-manager.io\` and \`trust.cert-manager.io\` API surfaces, which upstream charts provide identically."

mark_state cert-manager
log_ok "============================================="
log_ok " cert-manager + trust-manager ready (upstream)."
log_ok "============================================="
