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
# 2. Namespace
# -----------------------------------------------
if ! oc get ns "$NS" &>/dev/null; then
    log_info "Creating namespace '${NS}'..."
    oc create ns "$NS"
fi

# -----------------------------------------------
# 3. helm upgrade --install
# -----------------------------------------------
# OpenShift-specific overrides via a temp values file:
#   - controller.image.runAsUser / runAsGroup: null so OpenShift can assign
#     a UID from the namespace's [openshift.io/sa.scc.uid-range].
#   - controller.containerSecurityContext / podSecurityContext: minimal,
#     no fixed UIDs.
#   - admissionWebhooks.{createSecretJob,patchWebhookJob}.securityContext:
#     same — drop fixed UIDs.
# The chart template still emits a deprecated
# `container.seccomp.security.alpha.kubernetes.io/<container>` annotation
# on the admission jobs (kube-webhook-certgen v1.6.x), which OpenShift's SCC
# admission rejects. We grant `anyuid` (which by default tolerates seccomp
# alpha annotations) to the ServiceAccounts in the ingress-nginx namespace.
# The ingress-nginx controller adds NET_BIND_SERVICE capability and runs as
# uid 101 (www-data). Neither `restricted-v2` (requires UID in namespace range)
# nor `anyuid` (forbids adding capabilities) accept this. The `nonroot-v2`
# SCC allows non-zero UIDs AND adding NET_BIND_SERVICE.
log_info "Granting 'nonroot-v2' SCC to all ServiceAccounts in '${NS}'..."
oc adm policy add-scc-to-group nonroot-v2 "system:serviceaccounts:${NS}" >/dev/null
log_info "Also granting 'anyuid' (for the kube-webhook-certgen admission jobs)..."
oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${NS}" >/dev/null

VALUES_FILE="$(mktemp)"
trap 'rm -f "$VALUES_FILE"' EXIT
cat > "$VALUES_FILE" <<YAML
controller:
  service:
    type: ClusterIP
  ingressClassResource:
    name: ${INGRESS_CLASS}
    controllerValue: k8s.io/ingress-nginx
  ingressClass: ${INGRESS_CLASS}
  replicaCount: 1
  image:
    # The upstream container image expects to write into /etc/ingress-controller/ssl
    # (a directory in the image filesystem, NOT a volume), which is chown'd
    # to uid 101 (www-data). OpenShift's auto-assigned high UID gets a
    # permission-denied. Pin runAsUser to 101 — this requires the anyuid
    # SCC (granted below).
    runAsUser: 101
    runAsGroup: 82
    allowPrivilegeEscalation: false
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 101
    runAsGroup: 82
    seccompProfile:
      type: RuntimeDefault
  containerSecurityContext:
    runAsNonRoot: true
    runAsUser: 101
    runAsGroup: 82
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop: [ALL]
      add: [NET_BIND_SERVICE]
    seccompProfile:
      type: RuntimeDefault
  admissionWebhooks:
    enabled: true
    createSecretJob:
      securityContext:
        runAsNonRoot: true
        runAsUser: null
        runAsGroup: null
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
        readOnlyRootFilesystem: true
    patchWebhookJob:
      securityContext:
        runAsNonRoot: true
        runAsUser: null
        runAsGroup: null
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
        readOnlyRootFilesystem: true
    patch:
      securityContext:
        runAsNonRoot: true
        runAsUser: null
        runAsGroup: null
YAML

log_info "Installing ingress-nginx via helm (ClusterIP, ingressClass=${INGRESS_CLASS})..."
helm upgrade --install "$RELEASE_NAME" ingress-nginx/ingress-nginx \
    --namespace "$NS" \
    --values "$VALUES_FILE" \
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
