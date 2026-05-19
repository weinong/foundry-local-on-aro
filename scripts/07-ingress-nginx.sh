#!/usr/bin/env bash
# =============================================================================
# scripts/07-ingress-nginx.sh
#
# Install ingress-nginx for the Foundry Local extension to use as its
# external-endpoint controller. We expose it as ClusterIP only — the project
# scope is internal validation via `oc port-forward`.
#
# References:
#   - Foundry Local deploy doc (NGINX ingress prerequisite):
#     https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension#prerequisites
#   - ingress-nginx upstream chart:
#     https://kubernetes.github.io/ingress-nginx/
#
# OpenShift-specific notes:
#   - OpenShift ships its own Router (HAProxy) as ingressClass `openshift-default`.
#     We install ingress-nginx with a distinct ingressClassName=`nginx` so the
#     two controllers do not race for the same Ingress objects.
#   - ingress-nginx requires elevated SCC for its controller and admission
#     webhook (capabilities NET_BIND_SERVICE; in restricted-v2 it would not be
#     able to chown /etc/nginx files). We grant `anyuid` to its SA.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase H: ingress-nginx (ClusterIP)"
echo "============================================="

for cmd in oc helm; do
    check_command "$cmd" || exit 1
done

NS="${INGRESS_NAMESPACE}"
RELEASE_NAME="ingress-nginx"
CHART_REPO_URL="https://kubernetes.github.io/ingress-nginx"

# -----------------------------------------------
# 1. Helm repo
# -----------------------------------------------
log_info "Adding/updating ingress-nginx helm repo..."
helm repo add ingress-nginx "$CHART_REPO_URL" --force-update >/dev/null
helm repo update ingress-nginx >/dev/null
log_ok "Helm repo ready."

# -----------------------------------------------
# 2. Namespace + SCC
# -----------------------------------------------
if ! oc get ns "$NS" &>/dev/null; then
    log_info "Creating namespace '${NS}'..."
    oc create ns "$NS"
fi

# Grant SCCs to the SAs the chart will create. add-scc-to-user is idempotent
# and safe to apply before the SAs exist (the binding takes effect when the
# SAs are created).
SA_NAME="ingress-nginx"
SA_ADMISSION="ingress-nginx-admission"
log_info "Granting 'anyuid' SCC to ingress-nginx ServiceAccounts..."
for sa in "$SA_NAME" "$SA_ADMISSION"; do
    oc adm policy add-scc-to-user anyuid "system:serviceaccount:${NS}:${sa}" >/dev/null || true
done

# -----------------------------------------------
# 3. helm upgrade --install
# -----------------------------------------------
log_info "Installing ingress-nginx via helm (ClusterIP, ingressClass=${INGRESS_CLASS})..."
helm upgrade --install "$RELEASE_NAME" ingress-nginx/ingress-nginx \
    --namespace "$NS" \
    --set controller.service.type=ClusterIP \
    --set controller.ingressClassResource.name="$INGRESS_CLASS" \
    --set controller.ingressClassResource.controllerValue="k8s.io/ingress-nginx" \
    --set controller.ingressClass="$INGRESS_CLASS" \
    --set controller.admissionWebhooks.enabled=true \
    --set controller.replicaCount=1 \
    --wait --timeout 10m

# -----------------------------------------------
# 4. Verify
# -----------------------------------------------
log_info "Verifying ingress-nginx pods..."
oc -n "$NS" get pods -o wide

NOT_READY=$(oc -n "$NS" get pods --no-headers \
    | awk '$3!="Running" && $3!="Completed" { print $1 }' || true)
if [[ -n "$NOT_READY" ]]; then
    log_error "Some ingress-nginx pods are not Running:"
    echo "$NOT_READY"
    DIAG=$(oc -n "$NS" get pods -o wide 2>&1; \
           echo "---"; \
           oc -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -30)
    progress_log "ingress" "FAILED: ingress-nginx pods not Running. Diagnostics:
\`\`\`
${DIAG}
\`\`\`"
    exit 1
fi
log_ok "All ingress-nginx pods are Running."

log_info "Verifying IngressClass '${INGRESS_CLASS}' exists..."
if ! oc get ingressclass "$INGRESS_CLASS" &>/dev/null; then
    log_error "IngressClass '${INGRESS_CLASS}' not found."
    exit 1
fi
log_ok "IngressClass '${INGRESS_CLASS}' registered alongside OpenShift Router."

progress_log "ingress" "Installed upstream ingress-nginx in namespace \`${NS}\` with ingressClassName=\`${INGRESS_CLASS}\` (ClusterIP). **OpenShift divergence**: granted \`anyuid\` SCC to ingress-nginx ServiceAccounts; kept a distinct ingressClass so it does not collide with OpenShift Router's \`openshift-default\`."

mark_state ingress
log_ok "============================================="
log_ok " ingress-nginx ready. Next: make foundry-operator"
log_ok "============================================="
