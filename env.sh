#!/usr/bin/env bash
# =============================================================================
# Shared environment variables for Foundry Local on Azure Red Hat OpenShift.
# Source this file from each script: source "${REPO_ROOT}/env.sh"
# =============================================================================

# --- Repo root (env.sh lives at the repo root) ---
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="${_REPO_ROOT}"
export STATE_DIR="${STATE_DIR:-${REPO_ROOT}/.state}"
mkdir -p "${STATE_DIR}"

# --- Azure / ARO settings ---
export LOCATION="${LOCATION:-centralus}"
export RESOURCEGROUP="${RESOURCEGROUP:-aro-virt-test-rg}"
export CLUSTER="${CLUSTER:-aro-virt-test}"
export VNET_NAME="${VNET_NAME:-aro-vnet}"
export VNET_CIDR="${VNET_CIDR:-10.0.0.0/22}"
export MASTER_SUBNET="${MASTER_SUBNET:-master}"
export MASTER_SUBNET_CIDR="${MASTER_SUBNET_CIDR:-10.0.0.0/23}"
export WORKER_SUBNET="${WORKER_SUBNET:-worker}"
export WORKER_SUBNET_CIDR="${WORKER_SUBNET_CIDR:-10.0.2.0/23}"

# Worker VM size: Dsv5 or Dsv6 with >= 8 cores is enough for the CPU-only
# Foundry Local validation. GPU is out of scope for this project.
export WORKER_VM_SIZE="${WORKER_VM_SIZE:-Standard_D8s_v5}"
export WORKER_COUNT="${WORKER_COUNT:-3}"
export WORKER_DISK_SIZE_GB="${WORKER_DISK_SIZE_GB:-128}"

# Pinned only if someone wants to test against a specific OCP minor.
# Leave empty to let scripts/01-aro-infra.sh pick the latest 4.18+ version.
export TARGET_OCP_VERSION="${TARGET_OCP_VERSION:-}"

# --- Managed Identity names (9 required for managed-identity ARO) ---
export MI_CLUSTER="aro-cluster"
export MI_CCM="cloud-controller-manager"
export MI_INGRESS="ingress"
export MI_MACHINE_API="machine-api"
export MI_DISK_CSI="disk-csi-driver"
export MI_CLOUD_NET="cloud-network-config"
export MI_IMAGE_REG="image-registry"
export MI_FILE_CSI="file-csi-driver"
export MI_ARO_OP="aro-operator"

# --- Arc + Foundry Local settings ---
export ARC_CLUSTER_NAME="${ARC_CLUSTER_NAME:-${CLUSTER}-arc}"
export FOUNDRY_NAMESPACE="${FOUNDRY_NAMESPACE:-foundry-local-operator}"
export INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
export INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
export FOUNDRY_APP_NAME="${FOUNDRY_APP_NAME:-foundry-local-${CLUSTER}}"
export FOUNDRY_APP_FILE="${FOUNDRY_APP_FILE:-${REPO_ROOT}/.foundry-app.json}"
export KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REPO_ROOT}/kubeconfig}"
export PULL_SECRET_FILE="${PULL_SECRET_FILE:-${REPO_ROOT}/.pull-secret.txt}"

# --- Validate resource names (guard against injection via env overrides) ---
# Use `return` rather than `exit` so this file is safe to source interactively.
_envsh_die() {
  echo "$@" >&2
  if (return 0 2>/dev/null); then
    return 1
  else
    exit 1
  fi
}
for _var_name in CLUSTER RESOURCEGROUP ARC_CLUSTER_NAME FOUNDRY_APP_NAME; do
  _var_val="${!_var_name}"
  if [[ -n "$_var_val" && ! "$_var_val" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    _envsh_die "[ERROR] Invalid characters in $_var_name='$_var_val'. Only [a-zA-Z0-9._-] allowed."
    return 1 2>/dev/null || exit 1
  fi
done
unset _var_name _var_val

# --- Derived values (populated lazily) ---
# SUBSCRIPTION_ID is fetched on demand via require_azure_login. We do NOT
# call `az account show` at source time — that would slow every Makefile
# recipe and silently produce an empty value when the user is not logged in.
export SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"

require_azure_login() {
  if [[ -z "${SUBSCRIPTION_ID}" ]]; then
    SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null)" || true
  fi
  if [[ -z "${SUBSCRIPTION_ID}" ]]; then
    echo "[ERROR] Not logged in to Azure CLI. Run 'az login' first." >&2
    return 1
  fi
  export SUBSCRIPTION_ID
}

# Make every script that sources env.sh talk to the project's kubeconfig by
# default, instead of whatever ~/.kube/config the user has. Override with
# `KUBECONFIG=... make ...` when needed.
export KUBECONFIG="${KUBECONFIG:-${KUBECONFIG_FILE}}"

# --- Helper functions ---
log_info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_ok() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

check_command() {
  if ! command -v "$1" &>/dev/null; then
    log_error "Required command '$1' not found. Please install it first."
    return 1
  fi
}

# Validate a Red Hat pull secret file. Prints actionable error messages on
# stderr and returns 0 (valid) or 1 (missing or malformed). Safe to call under
# `set -e` because the non-zero return is the only failure path callers need
# to distinguish.
# Usage: if ! validate_pull_secret <file>; then ...; fi
validate_pull_secret() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "[ERROR] Pull secret not found at: $file" >&2
    echo "[ERROR] Download from: https://console.redhat.com/openshift/install/azure/aro-provisioned" >&2
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    echo "[WARN]  python3 not found — skipping pull-secret content check" >&2
    return 0
  fi
  if ! python3 -c "
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
assert 'auths' in d
" "$file" 2>/dev/null; then
    echo "[ERROR] Pull secret at $file is not a valid Red Hat pull secret." >&2
    echo "[ERROR] Expected a JSON file containing an 'auths' key." >&2
    return 1
  fi
  return 0
}

# Append a timestamped entry to docs/progress.md.
# Usage: progress_log "<phase>" "<message>"
progress_log() {
  local phase="$1"
  shift
  local message="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local file="${REPO_ROOT}/docs/progress.md"
  mkdir -p "$(dirname "$file")"
  {
    echo ""
    echo "## ${ts} — ${phase}"
    echo ""
    echo "${message}"
  } >> "${file}"
}

# Mark a phase complete with a sentinel under .state/. Use to make `make` resumable.
mark_state() {
  local phase="$1"
  : > "${STATE_DIR}/${phase}.done"
}

# True if a sentinel exists for the given phase.
is_state_done() {
  [[ -f "${STATE_DIR}/$1.done" ]]
}
