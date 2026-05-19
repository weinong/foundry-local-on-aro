#!/usr/bin/env bash
# =============================================================================
# scripts/09-validate.sh
#
# End-to-end validation: pick a small CPU-runnable model from the synced
# catalog, create a ModelDeployment, wait for it to be Running, run an
# inference call via API key, and update docs/validation-report.md.
#
# Reference:
#   https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-run-first-model
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/env.sh"

echo "============================================="
echo " Phase J: validation"
echo "============================================="

for cmd in oc kubectl jq curl python3 base64; do
    check_command "$cmd" || exit 1
done

DEPLOY_NAME="${FOUNDRY_VALIDATE_DEPLOY:-foundry-validate}"
RUNTIME="${FOUNDRY_VALIDATE_RUNTIME:-onnx-genai}"   # CPU-friendly
COMPUTE="${FOUNDRY_VALIDATE_COMPUTE:-cpu}"
MODEL_ALIAS_OVERRIDE="${FOUNDRY_VALIDATE_MODEL:-}"   # alias from catalog.json

# Guard against env-var injection into the YAML we'll apply.
for _v in DEPLOY_NAME RUNTIME COMPUTE; do
    _val="${!_v}"
    if [[ ! "$_val" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid characters in $_v='$_val'. Only [a-zA-Z0-9._-] allowed."
        exit 1
    fi
done
if [[ -n "$MODEL_ALIAS_OVERRIDE" && ! "$MODEL_ALIAS_OVERRIDE" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    log_error "Invalid FOUNDRY_VALIDATE_MODEL='$MODEL_ALIAS_OVERRIDE'."
    exit 1
fi
unset _v _val

# -----------------------------------------------
# 1. Fetch the catalog and pick a CPU-runnable generative model.
# -----------------------------------------------
log_info "Reading foundry-local-catalog ConfigMap..."
CATALOG_JSON=$(oc -n "$FOUNDRY_NAMESPACE" get configmap foundry-local-catalog \
    -o jsonpath='{.data.catalog\.json}' 2>/dev/null || echo "")

if [[ -z "$CATALOG_JSON" ]]; then
    log_error "foundry-local-catalog ConfigMap is empty or missing in namespace '${FOUNDRY_NAMESPACE}'."
    log_error "The catalog-sync job may still be in progress. Re-run 'make validate' after a few minutes."
    exit 1
fi

if [[ -n "$MODEL_ALIAS_OVERRIDE" ]]; then
    MODEL_NAME="$MODEL_ALIAS_OVERRIDE"
    log_info "Using user-provided model alias: ${MODEL_NAME}"
else
    log_info "Selecting a CPU + generative model from the catalog..."
    MODEL_NAME=$(echo "$CATALOG_JSON" | python3 - <<'PY'
import sys, json
catalog = json.load(sys.stdin)
candidates = []
for m in catalog.get("models", []):
    compute = m.get("supportedCompute") or []
    task = (m.get("task") or "").lower()
    framework = (m.get("framework") or "").lower()
    if "cpu" in [c.lower() for c in compute] and ("generative" in task or "text-generation" in task or "chat" in task):
        candidates.append(m)
if not candidates:
    sys.exit(0)
# Prefer ONNX-GenAI (CPU-friendly path), and the smallest by displayName heuristic.
candidates.sort(key=lambda m: (
    0 if "onnx" in (m.get("framework") or "").lower() else 1,
    len(m.get("displayName") or ""),
))
print(candidates[0].get("alias") or candidates[0].get("name", ""))
PY
)
    if [[ -z "$MODEL_NAME" ]]; then
        log_error "No CPU + generative model found in the catalog."
        log_error "Set FOUNDRY_VALIDATE_MODEL=<alias> to pick one manually."
        echo "$CATALOG_JSON" | python3 -c "import sys,json;print(json.dumps([m.get('alias') for m in json.load(sys.stdin).get('models',[])]))"
        exit 1
    fi
    log_ok "Selected model alias: ${MODEL_NAME}"
fi

if [[ ! "$MODEL_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    log_error "Selected model alias '${MODEL_NAME}' contains unexpected characters."
    exit 1
fi

# -----------------------------------------------
# 2. Apply ModelDeployment.
# -----------------------------------------------
MANIFEST=$(mktemp)
trap 'rm -f "$MANIFEST"' EXIT
cat > "$MANIFEST" <<YAML
apiVersion: foundrylocal.azure.com/v1
kind: ModelDeployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${FOUNDRY_NAMESPACE}
spec:
  model:
    catalog:
      name: ${MODEL_NAME}
      version: "latest"
  compute: ${COMPUTE}
  runtime: ${RUNTIME}
  workloadType: generative
  replicas: 1
  resources:
    requests:
      cpu: "1"
      memory: "4Gi"
    limits:
      cpu: "2"
      memory: "8Gi"
YAML

log_info "Applying ModelDeployment '${DEPLOY_NAME}' (model=${MODEL_NAME}, compute=${COMPUTE}, runtime=${RUNTIME})..."
oc apply -f "$MANIFEST"

# -----------------------------------------------
# 3. Wait for the deployment to be Ready.
# -----------------------------------------------
log_info "Waiting up to 20 min for ModelDeployment to be Running..."
DEADLINE=$(( $(date +%s) + 1200 ))
START_TS=$(date +%s)
while true; do
    PHASE=$(oc -n "$FOUNDRY_NAMESPACE" get modeldeployment "$DEPLOY_NAME" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    READY=$(oc -n "$FOUNDRY_NAMESPACE" get modeldeployment "$DEPLOY_NAME" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    log_info "  phase=${PHASE:-<none>} ready=${READY:-<none>}"
    if [[ "$READY" == "True" || "$PHASE" == "Running" || "$PHASE" == "Ready" ]]; then
        log_ok "Model is Running."
        break
    fi
    if [[ $(date +%s) -ge $DEADLINE ]]; then
        log_error "ModelDeployment did not become Ready in 20 min."
        DIAG=$(oc -n "$FOUNDRY_NAMESPACE" describe modeldeployment "$DEPLOY_NAME" 2>&1; \
               echo "---"; \
               oc -n "$FOUNDRY_NAMESPACE" get pods -l "foundry.azure.com/deployment=${DEPLOY_NAME}" -o wide 2>&1; \
               echo "---"; \
               oc -n "$FOUNDRY_NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 | tail -50)
        progress_log "validate" "FAILED: ModelDeployment ${DEPLOY_NAME} did not reach Ready. Diagnostics:
\`\`\`
${DIAG}
\`\`\`"
        exit 1
    fi
    sleep 20
done
DEPLOY_SECONDS=$(( $(date +%s) - START_TS ))
log_ok "Model became ready in ~${DEPLOY_SECONDS}s."

# -----------------------------------------------
# 4. Retrieve the API key and port-forward the model svc.
# -----------------------------------------------
log_info "Retrieving API key from secret ${DEPLOY_NAME}-api-keys..."
API_KEY_B64=$(oc -n "$FOUNDRY_NAMESPACE" get secret "${DEPLOY_NAME}-api-keys" \
    -o jsonpath='{.data.primary-key}' 2>/dev/null || echo "")
if [[ -z "$API_KEY_B64" ]]; then
    log_error "Could not retrieve api key secret. Is the deployment fully ready?"
    exit 1
fi
API_KEY=$(echo "$API_KEY_B64" | base64 --decode)

log_info "Starting port-forward to svc/${DEPLOY_NAME} on localhost:5000..."
PF_PID=""
PF_LOG=""
cleanup_pf() {
    if [[ -n "${PF_PID:-}" ]]; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
    [[ -n "${PF_LOG:-}" ]] && rm -f "$PF_LOG"
}
trap 'cleanup_pf; rm -f "$MANIFEST"' EXIT
PF_LOG=$(mktemp)
chmod 600 "$PF_LOG"
oc -n "$FOUNDRY_NAMESPACE" port-forward "svc/${DEPLOY_NAME}" 5000:5000 >"$PF_LOG" 2>&1 &
PF_PID=$!

# Give port-forward a moment to come up.
for _ in $(seq 1 20); do
    if curl -k -s -o /dev/null --max-time 2 "https://localhost:5000/healthz" \
        || curl -s -o /dev/null --max-time 2 "http://localhost:5000/healthz"; then
        break
    fi
    sleep 1
done

# -----------------------------------------------
# 5. Send a chat-completions request.
# -----------------------------------------------
PAYLOAD=$(jq -n --arg m "$MODEL_NAME" '{
  model: $m,
  messages: [{role:"user", content:"In one sentence, what city is the capital of France?"}],
  max_tokens: 64
}')

log_info "Sending chat-completions request..."
RESP_FILE=$(mktemp)
HTTP_CODE=$(curl -k -s -o "$RESP_FILE" -w '%{http_code}' \
    -X POST "https://localhost:5000/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "api-key: ${API_KEY}" \
    --max-time 60 \
    -d "$PAYLOAD" || echo "000")

log_info "HTTP status: ${HTTP_CODE}"
RESP_BODY=$(cat "$RESP_FILE")
rm -f "$RESP_FILE"

if [[ "$HTTP_CODE" != "200" ]]; then
    log_error "Inference call failed."
    echo "$RESP_BODY" | head -20
    progress_log "validate" "FAILED: inference call returned HTTP ${HTTP_CODE}.
\`\`\`
$(echo "$RESP_BODY" | head -50)
\`\`\`"
    exit 1
fi

ANSWER=$(echo "$RESP_BODY" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
# Sanitize for embedding in markdown: collapse whitespace, drop backticks, cap length.
ANSWER_REPORT=$(printf '%s' "$ANSWER" | tr '\n\r\t`' '    ' | head -c 200)
log_ok "Inference succeeded. Model said:"
echo "    ${ANSWER}"

# -----------------------------------------------
# 6. Update the validation report.
# -----------------------------------------------
REPORT="${REPO_ROOT}/docs/validation-report.md"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    echo ""
    echo "## Validation run — ${TS}"
    echo ""
    echo "- Model alias: \`${MODEL_NAME}\`"
    echo "- compute: \`${COMPUTE}\`, runtime: \`${RUNTIME}\`"
    echo "- ModelDeployment readiness time: ~${DEPLOY_SECONDS}s"
    echo "- Inference HTTP status: ${HTTP_CODE}"
    echo "- Sample answer (first 200 chars, whitespace collapsed):"
    echo ""
    echo "  > ${ANSWER_REPORT}"
} >> "$REPORT"
log_ok "Appended results to docs/validation-report.md"

progress_log "validate" "Inference success. Model \`${MODEL_NAME}\` ran on CPU; HTTP 200, sample answer (truncated): \"${ANSWER_REPORT}\""

mark_state validate
log_ok "============================================="
log_ok " Validation complete."
log_ok "============================================="
