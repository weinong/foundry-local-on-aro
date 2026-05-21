#!/usr/bin/env bash
# =============================================================================
# scripts/08-foundry-operator.sh
#
# Install the Foundry Local inference operator via Helm (OCI registry).
#
# Reference (preview docs):
#   helm.txt in this repo (Helm Chart Installation Guide from the Foundry team)
#
# Why helm instead of `az k8s-extension`:
#   The Arc-extension path (`Microsoft.Foundry`) returned "Extension type
#   microsoft.foundry doesn't have any supporting artifacts" against this
#   subscription. The helm chart is published publicly at
#   mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/
#   and is not gated on the preview access list.
#
# Entra auth is disabled (`entraAuth.enabled=false`) for this lab validation
# so we can verify the inference path with API-key auth without involving
# the Entra App registration sidecar wiring.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase I: Foundry inference operator (helm OCI)"
echo "============================================="

for cmd in oc helm; do
    check_command "$cmd" || exit 1
done

INFERENCE_OPERATOR_CHART_VERSION="${INFERENCE_OPERATOR_CHART_VERSION:-0.260430.8}"
CHART_OCI_REF="oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator"

# -----------------------------------------------
# 1. Ensure namespace exists with Helm-adoption metadata.
#
# OpenShift's auto-injection of pod-security labels on namespaces means
# Helm refuses to import the namespace it pre-creates as `--create-namespace`
# unless it has the helm ownership annotations. We pre-create explicitly to
# avoid that race.
# -----------------------------------------------
# Idempotent create-or-no-op (avoids check-then-create race under set -e).
oc create ns "$FOUNDRY_NAMESPACE" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc label namespace "$FOUNDRY_NAMESPACE" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null || true
oc annotate namespace "$FOUNDRY_NAMESPACE" meta.helm.sh/release-name=inference-operator --overwrite >/dev/null || true
oc annotate namespace "$FOUNDRY_NAMESPACE" meta.helm.sh/release-namespace="$FOUNDRY_NAMESPACE" --overwrite >/dev/null || true

# -----------------------------------------------
# 2. Pre-grant SCCs so operator + inference pods can start on OpenShift.
#
# Empirical findings from a real install:
#   - inference-operator and model-store pods run fine with nonroot-v2.
#   - telemetry-collector ships an init container that requires
#     runAsUser=0, NET_ADMIN + NET_RAW capabilities, and fsGroup=10001.
#     Only the `privileged` SCC permits all three on OpenShift.
# We grant the strict-but-sufficient set: nonroot-v2 (main pods),
# anyuid (chart-pinned UIDs), and privileged (telemetry sidecar init).
# `add-scc-to-group` is idempotent; the `|| true` guards transient API errors
# under set -e.
# -----------------------------------------------
log_info "Granting SCCs to ServiceAccounts in '${FOUNDRY_NAMESPACE}'..."
oc adm policy add-scc-to-group nonroot-v2 "system:serviceaccounts:${FOUNDRY_NAMESPACE}" >/dev/null || true
oc adm policy add-scc-to-group anyuid     "system:serviceaccounts:${FOUNDRY_NAMESPACE}" >/dev/null || true
oc adm policy add-scc-to-group privileged "system:serviceaccounts:${FOUNDRY_NAMESPACE}" >/dev/null || true

# -----------------------------------------------
# 3. Install the helm chart.
# -----------------------------------------------
log_info "Installing inference-operator helm chart ${INFERENCE_OPERATOR_CHART_VERSION}..."
helm upgrade --install inference-operator "$CHART_OCI_REF" \
    --version "$INFERENCE_OPERATOR_CHART_VERSION" \
    --namespace "$FOUNDRY_NAMESPACE" \
    --set entraAuth.enabled=false \
    --wait --timeout 15m || {
    log_error "helm install failed. Capturing diagnostics..."
    DIAG=$(oc -n "$FOUNDRY_NAMESPACE" get pods -o wide 2>&1; \
           echo "---"; \
           oc -n "$FOUNDRY_NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 | tail -50)
    progress_log "foundry-operator" "helm install FAILED. Diagnostics:
\`\`\`
${DIAG}
\`\`\`"
    exit 1
}

# -----------------------------------------------
# 4. Verify pods + CRDs.
# -----------------------------------------------
log_info "Verifying inference-operator pods..."
oc -n "$FOUNDRY_NAMESPACE" get pods -o wide

# Filter to chart-managed pods so unrelated debug pods (or completed catalog-
# sync jobs) don't trigger a false failure. `helm --wait` should have already
# blocked until these are Ready, so this is a belt-and-suspenders check.
NOT_READY=$(oc -n "$FOUNDRY_NAMESPACE" get pods \
    -l app.kubernetes.io/managed-by=Helm --no-headers 2>/dev/null \
    | awk '$3!="Running" && $3!="Completed" { print $1 }' || true)
if [[ -n "$NOT_READY" ]]; then
    log_warn "Some pods are not Running:"
    echo "$NOT_READY"
    DIAG=$(oc -n "$FOUNDRY_NAMESPACE" get pods -o wide 2>&1; \
           echo "---"; \
           oc -n "$FOUNDRY_NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 | tail -50)
    progress_log "foundry-operator" "Some pods not Running after helm install. Diagnostics:
\`\`\`
${DIAG}
\`\`\`"
    exit 1
fi
log_ok "All inference-operator pods are Running."

log_info "Verifying Foundry Local CRDs..."
FOUNDRY_CRDS=$(oc get crd -o name | grep -i foundry || true)
if [[ -z "$FOUNDRY_CRDS" ]]; then
    log_error "No CRDs with 'foundry' in name found."
    progress_log "foundry-operator" "FAILED: no Foundry CRDs registered after helm install."
    exit 1
fi
echo "$FOUNDRY_CRDS" | sed 's/^/    /'
log_ok "Foundry Local CRDs present."

# -----------------------------------------------
# 5. Show catalog state.
# -----------------------------------------------
log_info "Catalog ConfigMap summary:"
if oc -n "$FOUNDRY_NAMESPACE" get configmap foundry-local-catalog &>/dev/null; then
    MODEL_COUNT=$(oc get models -A --no-headers 2>/dev/null | wc -l)
    log_ok "  Found ${MODEL_COUNT} Model CRs after catalog sync."
else
    log_warn "  foundry-local-catalog ConfigMap not yet present (catalog sync may be in progress)."
fi

progress_log "foundry-operator" "Installed Foundry Local inference operator helm chart \`${INFERENCE_OPERATOR_CHART_VERSION}\` from \`${CHART_OCI_REF}\` into namespace \`${FOUNDRY_NAMESPACE}\` with \`entraAuth.enabled=false\` (API-key path). Granted \`nonroot-v2\` + \`anyuid\` SCCs to namespace ServiceAccounts. **Bypassed** the Arc-extension path because \`microsoft.foundry\` extension-type has no versions visible to this subscription."

mark_state foundry-operator
log_ok "============================================="
log_ok " Foundry inference operator ready. Next: make validate"
log_ok "============================================="
